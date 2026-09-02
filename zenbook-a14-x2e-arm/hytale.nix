{ inputs, pkgs, lib, ... }:

let
  # Same import as fex.nix -> identical store path -> the binfmt shim, the
  # launcher and the FEXServer all run the same FEX build.
  fexPkgs = import inputs.nixpkgs-fex { system = pkgs.stdenv.hostPlatform.system; };
  # FEX 2608 + one JIT option (HalfBarrierTSOAlways, env FEX_HALFBARRIERTSOALWAYS):
  # emit scalar TSO loads/stores directly as plain ldur/stur + DMB -- the form
  # FEX's SIGBUS handler otherwise backpatches in after an unaligned
  # acquire/release access faults. On the Snapdragon X2 Elite (16-byte fault
  # granularity) that fault-and-live-patch path fires constantly and left
  # threads of the NativeAOT client with corrupted state (false stack-canary
  # aborts, GC heap damage). Same instructions the backpatcher produces, same
  # footprint, no live code modification, TSO semantics preserved.
  fex = fexPkgs.fex.overrideAttrs (old: {
    # Keep symbols so a FEX host crash can be read from the coredump.
    cmakeBuildType = "RelWithDebInfo";
    dontStrip = true;
    patches = (old.patches or []) ++ [
      (pkgs.writeText "fex-halfbarrier-tso-always.patch" ''
        --- a/FEXCore/Source/Interface/Config/Config.json.in
        +++ b/FEXCore/Source/Interface/Config/Config.json.in
        @@ -467,6 +467,15 @@
                   "Can be dangerous due to aligned loadstores through the same code now become non-atomic."
                 ]
               },
        +      "HalfBarrierTSOAlways": {
        +        "Type": "bool",
        +        "Default": "false",
        +        "Desc": [
        +          "When TSO emulation is enabled, emit scalar loads and stores directly in the half-barrier form",
        +          "(plain load/store plus DMB) instead of acquire/release instructions that are backpatched on SIGBUS.",
        +          "Avoids the unaligned-access SIGBUS path and live code patching entirely, at some throughput cost."
        +        ]
        +      },
               "StrictInProcessSplitLocks": {
                 "Type": "bool",
                 "Default": "false",
        --- a/FEXCore/Source/Interface/Context/Context.h
        +++ b/FEXCore/Source/Interface/Context/Context.h
        @@ -348,6 +348,7 @@
             FEX_CONFIG_OPT(Is64BitMode, IS64BIT_MODE);
             FEX_CONFIG_OPT(TSOEnabled, TSOENABLED);
             FEX_CONFIG_OPT(VectorTSOEnabled, VECTORTSOENABLED);
        +    FEX_CONFIG_OPT(HalfBarrierTSOAlways, HALFBARRIERTSOALWAYS);
             FEX_CONFIG_OPT(MemcpySetTSOEnabled, MEMCPYSETTSOENABLED);
             FEX_CONFIG_OPT(SMCChecks, SMCCHECKS);
             FEX_CONFIG_OPT(MaxInstPerBlock, MAXINST);
        @@ -430,6 +431,11 @@
             return VectorAtomicTSOEmulationEnabled;
           }

        +  // If scalar TSO loads/stores should be emitted in the half-barrier form up front.
        +  bool IsHalfBarrierTSOAlways() const {
        +    return AtomicTSOEmulationEnabled && Config.HalfBarrierTSOAlways;
        +  }
        +
           // If atomic-based TSO emulation is enabled for memcpy operations.
           bool IsMemcpyAtomicTSOEnabled() const {
             return MemcpyAtomicTSOEmulationEnabled;
        --- a/FEXCore/Source/Interface/Core/JIT/MemoryOps.cpp
        +++ b/FEXCore/Source/Interface/Core/JIT/MemoryOps.cpp
        @@ -776,7 +776,23 @@
             LOGMAN_THROW_A_FMT(Op->OffsetType == IR::MemOffsetType::SXTX, "unexpected offset type");
           }

        -  if (CTX->HostFeatures.SupportsTSOImm9 && Op->Class == IR::RegClass::GPR) {
        +  if (CTX->IsHalfBarrierTSOAlways() && Op->Class == IR::RegClass::GPR && OpSize != IR::OpSize::i8Bit) {
        +    // Same code the SIGBUS handler would backpatch to (LDUR + DMB ISHLD),
        +    // emitted up front: no unaligned-access fault, no live code patching.
        +    const auto Dst = GetReg(Node);
        +    uint64_t Offset = 0;
        +    if (!Op->Offset.IsInvalid()) {
        +      bool IsInline = IsInlineConstant(Op->Offset, &Offset);
        +      LOGMAN_THROW_A_FMT(IsInline, "expected immediate");
        +    }
        +    switch (OpSize) {
        +    case IR::OpSize::i16Bit: ldurh(Dst, MemReg, Offset); break;
        +    case IR::OpSize::i32Bit: ldur(Dst.W(), MemReg, Offset); break;
        +    case IR::OpSize::i64Bit: ldur(Dst.X(), MemReg, Offset); break;
        +    default: LOGMAN_MSG_A_FMT("Unhandled LoadMemTSO size: {}", OpSize); break;
        +    }
        +    dmb(ARMEmitter::BarrierScope::ISHLD);
        +  } else if (CTX->HostFeatures.SupportsTSOImm9 && Op->Class == IR::RegClass::GPR) {
             const auto Dst = GetReg(Node);
             uint64_t Offset = 0;
             if (!Op->Offset.IsInvalid()) {
        @@ -1787,7 +1803,23 @@
             LOGMAN_THROW_A_FMT(Op->OffsetType == IR::MemOffsetType::SXTX, "unexpected offset type");
           }

        -  if (CTX->HostFeatures.SupportsTSOImm9 && Op->Class == IR::RegClass::GPR) {
        +  if (CTX->IsHalfBarrierTSOAlways() && Op->Class == IR::RegClass::GPR && OpSize != IR::OpSize::i8Bit) {
        +    // Same code the SIGBUS handler would backpatch to (DMB ISH + STUR),
        +    // emitted up front: no unaligned-access fault, no live code patching.
        +    const auto Src = GetZeroableReg(Op->Value);
        +    uint64_t Offset = 0;
        +    if (!Op->Offset.IsInvalid()) {
        +      bool IsInline = IsInlineConstant(Op->Offset, &Offset);
        +      LOGMAN_THROW_A_FMT(IsInline, "expected immediate");
        +    }
        +    dmb(ARMEmitter::BarrierScope::ISH);
        +    switch (OpSize) {
        +    case IR::OpSize::i16Bit: sturh(Src, MemReg, Offset); break;
        +    case IR::OpSize::i32Bit: stur(Src.W(), MemReg, Offset); break;
        +    case IR::OpSize::i64Bit: stur(Src.X(), MemReg, Offset); break;
        +    default: LOGMAN_MSG_A_FMT("Unhandled StoreMemTSO size: {}", OpSize); break;
        +    }
        +  } else if (CTX->HostFeatures.SupportsTSOImm9 && Op->Class == IR::RegClass::GPR) {
             const auto Src = GetZeroableReg(Op->Value);
             uint64_t Offset = 0;
             if (!Op->Offset.IsInvalid()) {
      '')
      # The GL thunk's glXGetProcAddress table lacked GL_EXT_texture_storage,
      # which Mesa advertises: the client trusts the extension string, gets
      # NULL for glTexStorage2DEXT and jumps to 0 at the first texture upload.
      (pkgs.writeText "fex-gl-thunk-texstorage-ext.patch" ''
        --- a/ThunkLibs/libGL/libGL_interface.cpp
        +++ b/ThunkLibs/libGL/libGL_interface.cpp
        @@ -5055,6 +5055,14 @@
         struct fex_gen_config<glTexStorage3D> {};
         template<>
         struct fex_gen_config<glTexStorage3DMultisample> {};
        +// GL_EXT_texture_storage (advertised by Mesa; returning NULL for these makes
        +// callers that trust the extension string jump to 0).
        +template<>
        +struct fex_gen_config<glTexStorage1DEXT> {};
        +template<>
        +struct fex_gen_config<glTexStorage2DEXT> {};
        +template<>
        +struct fex_gen_config<glTexStorage3DEXT> {};
         template<>
         struct fex_gen_config<glTexStorageMem1DEXT> {};
         template<>
      '')
      # ROOT CAUSE of the FEX-side corruption: FEX-2608's shared code buffers
      # are versioned -- old buffers stay executable for threads that have not
      # moved to the latest one -- but SignalDelegator classifies "signal landed
      # in JIT code" with IsAddressInCodeBuffer(), which only knows the
      # receiving thread's *current* buffer. A signal landing in an older
      # buffer is treated as "not in JIT": the host registers are not spilled
      # and the guest signal frame is built from a stale RSP, i.e. written
      # over live stack data (stack-canary aborts in sentry-native, a corrupt
      # on-stack FILE in sscanf, RSP=0 frames -> FEX SIGSEGV in SetupFrame_x64,
      # GC root damage). Fix: a lock-free registry of all live CodeBuffer
      # ranges, consulted from the signal path.
      (pkgs.writeText "fex-live-codebuffers-signal.patch" ''
        --- a/FEXCore/Source/Interface/Core/SharedCodeBufferManager.h
        +++ b/FEXCore/Source/Interface/Core/SharedCodeBufferManager.h
        @@ -19,6 +19,18 @@
         }

         namespace FEXCore::CPU {
        +/**
        + * Registry of every live CodeBuffer's address range, written by CodeBuffer's
        + * constructor/destructor and read lock-free from the signal handler path.
        + *
        + * Old CodeBuffer versions stay executable for threads that have not moved to
        + * the latest one yet, so a signal can land on a host PC that is JIT code but
        + * not in the receiving thread's CurrentCodeBuffer. Classifying that as
        + * "not in JIT" skips the SRA spill and builds the guest signal frame from a
        + * stale RSP -- onto live stack data of the thread.
        + */
        +bool IsAddressInAnyLiveCodeBuffer(uintptr_t Address);
        +
         struct CodeBuffer {
           uint8_t* Ptr;
           size_t AllocatedSize; // including guard page; see UsableSize()
        --- a/FEXCore/Source/Interface/Core/SharedCodeBufferManager.cpp
        +++ b/FEXCore/Source/Interface/Core/SharedCodeBufferManager.cpp
        @@ -11,7 +11,56 @@
         #include <FEXCore/Utils/PrctlUtils.h>
         #endif

        +#include <atomic>
        +
         namespace FEXCore::CPU {
        +namespace {
        +// Append-only slots; a freed buffer clears its slot. Readers run in signal
        +// handlers, so no locks: each slot is (Begin, End) with End written last on
        +// registration and Begin cleared first on removal.
        +constexpr size_t MAX_LIVE_CODE_BUFFERS = 256;
        +struct LiveCodeBufferRange {
        +  std::atomic<uintptr_t> Begin {0};
        +  std::atomic<uintptr_t> End {0};
        +};
        +LiveCodeBufferRange LiveCodeBuffers[MAX_LIVE_CODE_BUFFERS];
        +
        +void RegisterLiveCodeBuffer(uintptr_t Begin, uintptr_t End) {
        +  for (auto& Slot : LiveCodeBuffers) {
        +    uintptr_t Expected = 0;
        +    if (Slot.Begin.compare_exchange_strong(Expected, Begin, std::memory_order_acq_rel)) {
        +      Slot.End.store(End, std::memory_order_release);
        +      return;
        +    }
        +  }
        +  LogMan::Msg::EFmt("Live CodeBuffer registry is full");
        +}
        +
        +void UnregisterLiveCodeBuffer(uintptr_t Begin) {
        +  for (auto& Slot : LiveCodeBuffers) {
        +    if (Slot.Begin.load(std::memory_order_acquire) == Begin) {
        +      Slot.Begin.store(0, std::memory_order_release);
        +      Slot.End.store(0, std::memory_order_release);
        +      return;
        +    }
        +  }
        +}
        +} // namespace
        +
        +bool IsAddressInAnyLiveCodeBuffer(uintptr_t Address) {
        +  for (const auto& Slot : LiveCodeBuffers) {
        +    const uintptr_t Begin = Slot.Begin.load(std::memory_order_acquire);
        +    if (!Begin) {
        +      continue;
        +    }
        +    const uintptr_t End = Slot.End.load(std::memory_order_acquire);
        +    if (Address >= Begin && Address < End) {
        +      return true;
        +    }
        +  }
        +  return false;
        +}
        +
         static constexpr size_t INITIAL_CODE_SIZE = 1024 * 1024 * 16;
         // We don't want to move above 128MB atm because that means we will have to encode longer jumps
         static constexpr size_t MAX_CODE_SIZE = 1024 * 1024 * 128;
        @@ -34,9 +83,13 @@
           FEXCore::Allocator::VirtualTHPControl(Ptr, Size, FEXCore::Allocator::THPControl::Enable);

           LookupCache = fextl::make_unique<GuestToHostMap>();
        +
        +  // Usable range only: the guard page is never executed.
        +  RegisterLiveCodeBuffer(reinterpret_cast<uintptr_t>(Ptr), LastPageAddr);
         }

         CodeBuffer::~CodeBuffer() {
        +  UnregisterLiveCodeBuffer(reinterpret_cast<uintptr_t>(Ptr));
           FEXCore::Allocator::VirtualFree(Ptr, AllocatedSize);
         }

        --- a/FEXCore/Source/Interface/Context/Context.cpp
        +++ b/FEXCore/Source/Interface/Context/Context.cpp
        @@ -53,7 +53,8 @@
         }

         bool FEXCore::Context::ContextImpl::IsAddressInCodeBuffer(FEXCore::Core::InternalThreadState* Thread, uintptr_t Address) const {
        -  return Thread->CPUBackend->IsAddressInCodeBuffer(Address) || CodeCache.IsAddressInMappedCodeBuffer(Address);
        +  return Thread->CPUBackend->IsAddressInCodeBuffer(Address) || CodeCache.IsAddressInMappedCodeBuffer(Address) ||
        +         FEXCore::CPU::IsAddressInAnyLiveCodeBuffer(Address);
         }

         bool FEXCore::Context::ContextImpl::RequiresRelocatableConstants() const {
      '')
      # Second half of the same bug: FEX's own SIGBUS/SIGSEGV/SIGILL host
      # handlers ran with async signals unmasked, so the GC's SIGRTMIN could
      # nest inside the unaligned-access backpatcher (constant on the X2 Elite
      # with its 16-byte fault granularity), get deferred, and be delivered
      # from host context with the JIT registers never spilled. Block async
      # signals for the duration of those handlers.
      (pkgs.writeText "fex-required-handlers-mask.patch" ''
        --- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
        +++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
        @@ -794,6 +794,18 @@
           SignalHandler.HostAction.restorer = sigrestore;
         #endif

        +  // FEX's own synchronous handlers (SIGSEGV/SIGBUS/SIGILL/pause) run host code
        +  // that may enter signal-deferring sections while the JIT's registers are still
        +  // live and unspilled (e.g. the unaligned-access backpatcher). An asynchronous
        +  // guest signal nesting inside such a handler gets deferred and is later
        +  // delivered from a host-code PC, so the guest signal frame is built from the
        +  // stale thread state. Block everything except the other required signals for
        +  // the duration of these handlers; the kernel redelivers on return, in JIT
        +  // context, where the state can be spilled correctly.
        +  if (SignalHandler.Required.load(std::memory_order_relaxed)) {
        +    SignalHandler.HostAction.sa_mask = ~0ULL;
        +  }
        +
           // Walk the signals we have that are required and make sure to remove it from the mask
           // This'll likely be SIGILL, SIGBUS, SIG63

      '')
      # The actual stale-state bug: JIT ops that call out to host code (Thunk --
      # vDSO clock_gettime and every GL call --, CPUID, XGetBV,
      # ThreadRemoveCodeEntry, MonoBackpatcherWrite) spill the guest registers
      # to State, call, then refill; only Syscall told the signal handler about
      # it (InSyscallInfo, GPRs only). A signal landing after the host call
      # returned had its context "spilled" from the callee's leftover host
      # registers (RSP = 0 was one such leftover), and FPRs/flags were always
      # overwritten. All host-call windows now mark the state as fully spilled
      # (InSyscallInfo bit 31) and SpillSRA honours it.
      (pkgs.writeText "fex-hostcall-window.patch" ''
        --- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
        +++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
        @@ -107,6 +107,12 @@
         #ifdef ARCHITECTURE_arm64
           Thread->CurrentFrame->State.rip = CTX->RestoreRIPFromHostPC(Thread, ArchHelpers::Context::GetPc(ucontext));

        +  if (IgnoreMask & 0x80000000U) {
        +    // Host-call window (thunk, syscall, CPUID, ...): the JIT already spilled the
        +    // complete guest state and the host registers hold the callee's garbage.
        +    return;
        +  }
        +
           for (size_t i = 0; i < Config.SRAGPRCount; i++) {
             const uint8_t SRAIdxMap = Config.SRAGPRMapping[i];
             if (IgnoreMask & (1U << SRAIdxMap)) {
        @@ -305,7 +311,8 @@
               // We need to spill SRA but only some of it, since some values have already been spilled
               // Lower 16 bits tells us which registers are already spilled to the context
               // So we ignore spilling those ones
        -      IgnoreMask = Frame->InSyscallInfo & 0xFFFF;
        +      // Bit 31: the JIT spilled everything (GPRs, FPRs, flags) before calling out to host code.
        +      IgnoreMask = Frame->InSyscallInfo & 0x8000FFFF;
             } else {
               // We must spill everything
               IgnoreMask = 0;
        --- a/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp
        +++ b/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp
        @@ -297,7 +297,8 @@
           // Still without overwriting registers that matter
           // 16bit LoadConstant to be a single instruction
           // This gives the signal handler a value to check to see if we are in a syscall at all
        -  LoadConstant(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r0, GPRSpillMask & 0xFFFF);
        +  // Bit 31: FPRs and flags were spilled as well (FPRSpillMask is ~0).
        +  LoadConstant(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r0, (GPRSpillMask & 0xFFFF) | 0x80000000ULL);
           str(ARMEmitter::XReg::x0, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));

           uint64_t SPOffset = AlignUp(FEXCore::HLE::SyscallArguments::MAX_ARGS * 8, 16);
        @@ -358,6 +359,11 @@
                                   .NZCV = false,
                                 });

        +  // Everything is in State now. Tell the signal handler so that a signal landing in
        +  // this host-call window does not spill the host callee's leftover registers over it.
        +  LoadConstant(ARMEmitter::Size::i64Bit, TMP1, 0x8000FFFFULL);
        +  str(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));
        +
           PushDynamicRegs(TMP1);

           mov(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r0, GetReg(Op->ArgPtr));
        @@ -375,6 +381,7 @@
           FillStaticRegs({
             .NZCV = false,
           });
        +  str(ARMEmitter::XReg::zr, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));
         }

         DEF_OP(ValidateCode) {
        @@ -429,6 +436,11 @@
           PushDynamicRegs(TMP4);
           SpillStaticRegs(TMP4);

        +  // Everything is in State now. Tell the signal handler so that a signal landing in
        +  // this host-call window does not spill the host callee's leftover registers over it.
        +  LoadConstant(ARMEmitter::Size::i64Bit, TMP4, 0x8000FFFFULL);
        +  str(TMP4, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));
        +
           // Arguments are passed as follows:
           // X0: Thread
           // X1: RIP
        @@ -444,6 +456,7 @@
             blr(ARMEmitter::Reg::r2);
           }
           FillStaticRegs();
        +  str(ARMEmitter::XReg::zr, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));

           // Fix the stack and any values that were stepped on
           PopDynamicRegs();
        @@ -459,6 +472,11 @@
           PushDynamicRegs(TMP4);
           SpillStaticRegs(TMP4);

        +  // Everything is in State now. Tell the signal handler so that a signal landing in
        +  // this host-call window does not spill the host callee's leftover registers over it.
        +  LoadConstant(ARMEmitter::Size::i64Bit, TMP4, 0x8000FFFFULL);
        +  str(TMP4, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));
        +
           // x0 = CPUID Handler
           // x1 = CPUID Function
           // x2 = CPUID Leaf
        @@ -482,6 +500,7 @@
           }

           FillStaticRegs();
        +  str(ARMEmitter::XReg::zr, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));

           PopDynamicRegs();

        @@ -499,6 +518,11 @@
           PushDynamicRegs(TMP4);
           SpillStaticRegs(TMP4);

        +  // Everything is in State now. Tell the signal handler so that a signal landing in
        +  // this host-call window does not spill the host callee's leftover registers over it.
        +  LoadConstant(ARMEmitter::Size::i64Bit, TMP4, 0x8000FFFFULL);
        +  str(TMP4, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));
        +
           mov(ARMEmitter::Size::i32Bit, ARMEmitter::Reg::r1, GetReg(Op->Function));

           // x0 = CPUID Handler
        @@ -516,6 +540,7 @@
           }

           FillStaticRegs();
        +  str(ARMEmitter::XReg::zr, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));

           PopDynamicRegs();

        --- a/FEXCore/Source/Interface/Core/JIT/MiscOps.cpp
        +++ b/FEXCore/Source/Interface/Core/JIT/MiscOps.cpp
        @@ -325,6 +325,11 @@
           PushDynamicRegs(TMP1);
           SpillStaticRegs(TMP1);

        +  // Everything is in State now. Tell the signal handler so that a signal landing in
        +  // this host-call window does not spill the host callee's leftover registers over it.
        +  LoadConstant(ARMEmitter::Size::i64Bit, TMP1, 0x8000FFFFULL);
        +  str(TMP1, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));
        +
           mov(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r0, STATE.R());
           mov(ARMEmitter::Size::i64Bit, ARMEmitter::Reg::r1, IR::OpSizeToSize(Op->Size));

        @@ -352,6 +357,7 @@
         #endif

           FillStaticRegs();
        +  str(ARMEmitter::XReg::zr, STATE, offsetof(FEXCore::Core::CpuStateFrame, InSyscallInfo));
           PopDynamicRegs();
         }

      '')
      # Diagnostic: a synchronous fault in FEX's own host code used to be
      # delivered to the guest (which then resumed past the syscall with the
      # host operation abandoned). Abort instead so the core shows the frames.
      (pkgs.writeText "fex-abort-on-host-fault.patch" ''
        --- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
        +++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp
        @@ -340,6 +340,19 @@
             }
           }

        +  {
        +    // A synchronous fault whose PC is neither JIT code nor the dispatcher is a
        +    // fault in FEX's own host code (or a thunk's host library). Handing it to
        +    // the guest resumes the guest past the syscall/thunk while the host frame is
        +    // abandoned mid-operation (locks held, tracking half-updated). Die here so
        +    // the core carries the real host frames.
        +    const auto* HostSigInfo = static_cast<const siginfo_t*>(info);
        +    const bool Synchronous = (Signal == SIGSEGV || Signal == SIGBUS || Signal == SIGILL || Signal == SIGFPE) && HostSigInfo->si_code > 0;
        +    if (Synchronous && !WasInJIT && !IsAddressInDispatcher(OldPC)) {
        +      abort();
        +    }
        +  }
        +
           uint64_t OldGuestSP = Frame->State.gregs[FEXCore::X86State::REG_RSP];
           uint64_t NewGuestSP = OldGuestSP;

      '')
      # Torn fast-path read: the JIT's ret/L1 fast paths ldp a (guest RIP,
      # host address) pair and only compare the RIP half before ret/br to the
      # host half, while other threads clear those entries (L1 word by word,
      # the call-ret stack via madvise DONTNEED, which FEX's own comment calls
      # non-atomic). A torn read = still-matching RIP + zeroed host address
      # = ret to 0 (the host PC 0 core, LR = the guest call's bl). Require a
      # non-zero host address before taking either fast path.
      (pkgs.writeText "fex-torn-fastpath.patch" ''
        --- a/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp
        +++ b/FEXCore/Source/Interface/Core/JIT/BranchOps.cpp
        @@ -187,13 +187,22 @@
         #endif
           } else {
             ARMEmitter::ForwardLabel SkipFullLookup;
        +    ARMEmitter::ForwardLabel NoCallRetMatch;
        +    ARMEmitter::ForwardLabel NoL1Match;
             auto RipReg = GetReg(Op->NewRIP);

        +    // Both fast paths below read a (guest RIP, host address) pair with a single ldp
        +    // while another thread may be clearing it (L1 entries are overwritten word by
        +    // word during invalidation, and the call-ret stack is zeroed with madvise).
        +    // A torn read can pair a still-matching RIP with an already-zeroed host
        +    // address; only take the fast path if the host address is non-zero.
             if (Op->Hint == IR::BranchHint::Return) {
               // First try to pop from the call-ret stack, otherwise follow the normal path (but ending in a ret)
               ldp<ARMEmitter::IndexType::POST>(TMP1, TMP2, REG_CALLRET_SP, 0x10);
               sub(TMP1, TMP1, RipReg.X());
        -      (void)cbz(ARMEmitter::Size::i64Bit, TMP1, &SkipFullLookup);
        +      (void)cbnz(ARMEmitter::Size::i64Bit, TMP1, &NoCallRetMatch);
        +      (void)cbnz(ARMEmitter::Size::i64Bit, TMP2, &SkipFullLookup);
        +      (void)Bind(&NoCallRetMatch);
             }

             // L1 Cache
        @@ -208,7 +217,9 @@

             // Note: sub+cbnz used over cmp+br to preserve flags.
             sub(TMP1, TMP1, RipReg.X());
        -    (void)cbz(ARMEmitter::Size::i64Bit, TMP1, &SkipFullLookup);
        +    (void)cbnz(ARMEmitter::Size::i64Bit, TMP1, &NoL1Match);
        +    (void)cbnz(ARMEmitter::Size::i64Bit, TMP2, &SkipFullLookup);
        +    (void)Bind(&NoL1Match);
             ldr(TMP2, STATE, offsetof(FEXCore::Core::CpuStateFrame, Pointers.DispatcherLoopTop));
             str(RipReg.X(), STATE, offsetof(FEXCore::Core::CpuStateFrame, State.rip));

      '')
      # THE root cause of the stale-RSP signal frames: RestoreFrame_* restores
      # Frame->InSyscallInfo only in the "guest modified RIP" branch. The
      # guest's rt_sigreturn is itself a JIT syscall op that set the marker,
      # and the normal return jumps straight back to the delivery context, so
      # its clearing epilogue never runs: the marker stays set, the next signal
      # that lands in JIT code skips spilling the live registers (RSP among
      # them) and builds its frame from the state of the previous delivery, one
      # call level up, over live stack data (sentry's canary, sscanf's FILE,
      # GC roots; Go's preemption signals hit the same thing). Restore it
      # unconditionally. Also let the SMC fault path honour the bit-31 marker.
      (pkgs.writeText "fex-sigreturn-insyscall.patch" ''
        --- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
        +++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
        @@ -127,12 +127,17 @@
           auto* guest_uctx = reinterpret_cast<FEXCore::x86_64::ucontext_t*>(Context->UContextLocation);
           [[maybe_unused]] auto* guest_siginfo = reinterpret_cast<siginfo_t*>(Context->SigInfoLocation);

        +  // Restore the InSyscallInfo that was current when the signal was delivered.
        +  // Unconditionally: the guest's rt_sigreturn is itself a syscall op that set
        +  // the marker, and returning straight to the delivery context skips its
        +  // clearing epilogue. Leaving it set makes the next signal that lands in JIT
        +  // code skip spilling the live registers (including RSP) and build its frame
        +  // from stale state one call level up -- on top of live stack data.
        +  Frame->InSyscallInfo = Context->InSyscallInfo;
        +
           // If the guest modified the RIP then we need to take special precautions here
           if (Context->OriginalRIP != guest_uctx->uc_mcontext.gregs[FEXCore::x86_64::FEX_REG_RIP] || Context->FaultToTopAndGeneratedException) {

        -    // Restore previous `InSyscallInfo` structure.
        -    Frame->InSyscallInfo = Context->InSyscallInfo;
        -
             // Hack! Go back to the top of the dispatcher top
             // This is only safe inside the JIT rather than anything outside of it
             ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
        @@ -208,11 +213,16 @@
         void SignalDelegator::RestoreFrame_ia32(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                                 FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
           SigFrame_i32* guest_uctx = reinterpret_cast<SigFrame_i32*>(Context->UContextLocation);
        +  // Restore the InSyscallInfo that was current when the signal was delivered.
        +  // Unconditionally: the guest's rt_sigreturn is itself a syscall op that set
        +  // the marker, and returning straight to the delivery context skips its
        +  // clearing epilogue. Leaving it set makes the next signal that lands in JIT
        +  // code skip spilling the live registers (including RSP) and build its frame
        +  // from stale state one call level up -- on top of live stack data.
        +  Frame->InSyscallInfo = Context->InSyscallInfo;
        +
           // If the guest modified the RIP then we need to take special precautions here
           if (Context->OriginalRIP != guest_uctx->sc.ip || Context->FaultToTopAndGeneratedException) {
        -    // Restore previous `InSyscallInfo` structure.
        -    Frame->InSyscallInfo = Context->InSyscallInfo;
        -
             // Hack! Go back to the top of the dispatcher top
             // This is only safe inside the JIT rather than anything outside of it
             ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
        @@ -286,12 +296,17 @@
         void SignalDelegator::RestoreRTFrame_ia32(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                                   FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
           RTSigFrame_i32* guest_uctx = reinterpret_cast<RTSigFrame_i32*>(Context->UContextLocation);
        +  // Restore the InSyscallInfo that was current when the signal was delivered.
        +  // Unconditionally: the guest's rt_sigreturn is itself a syscall op that set
        +  // the marker, and returning straight to the delivery context skips its
        +  // clearing epilogue. Leaving it set makes the next signal that lands in JIT
        +  // code skip spilling the live registers (including RSP) and build its frame
        +  // from stale state one call level up -- on top of live stack data.
        +  Frame->InSyscallInfo = Context->InSyscallInfo;
        +
           // If the guest modified the RIP then we need to take special precautions here
           if (Context->OriginalRIP != guest_uctx->uc.uc_mcontext.gregs[FEXCore::x86::FEX_REG_EIP] || Context->FaultToTopAndGeneratedException) {

        -    // Restore previous `InSyscallInfo` structure.
        -    Frame->InSyscallInfo = Context->InSyscallInfo;
        -
             // Hack! Go back to the top of the dispatcher top
             // This is only safe inside the JIT rather than anything outside of it
             ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
        --- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp
        +++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp
        @@ -121,7 +121,7 @@
               // If we are not in a single-instruction block, and the SMC write address could intersect with the current block,
               // reconstruct the context and repeat the faulting instruction as a single-instruction block so any SMC it performs
               // is immediately picked up.
        -      ThreadObject->SignalInfo.Delegator->SpillSRA(Thread, ucontext, Thread->CurrentFrame->InSyscallInfo & 0xFFFF);
        +      ThreadObject->SignalInfo.Delegator->SpillSRA(Thread, ucontext, Thread->CurrentFrame->InSyscallInfo & 0x8000FFFF);

               // Adjust context to return to the dispatcher, reloading SRA from thread state
               const auto& Config = ThreadObject->SignalInfo.Delegator->GetConfig();
      '')
    ];
  });
  # box64 master rather than 0.4.4: post-release syscall/wrapper fixes that
  # match the client's startup failure exactly -- getdents (#4332), clone
  # (#4330), fcntl (#4328), madvise (#4334), signal FPU state (#4331).
  # 0.4.4 corrupts the host heap right after SDL_Init/joystick enumeration
  # ("corrupted size vs. prev_size"), invariant to dynarec/interpreter,
  # STRONGMEM, wrappers, CPU-feature exposure and OpenSSL code paths.
  box64 = fexPkgs.box64.overrideAttrs (old: {
    version = "0.4.4-unstable-2026-09-01";
    src = pkgs.fetchFromGitHub {
      owner = "ptitSeb";
      repo = "box64";
      rev = "65702d61c3c8460c249e76354b1d5824a081592b";
      hash = "sha256-SIs8yR6XGpauN8jjqmhxaYu1arHVbQyB4BnnvgwBz0w=";
    };
    # Keep symbols: box64's crash dumps then name the wrapper on top of the
    # native backtrace instead of bare addresses.
    cmakeBuildType = "RelWithDebInfo";
    dontStrip = true;
    # ROOT CAUSE of the client's startup heap corruption ("corrupted size vs.
    # prev_size" / "double free or corruption (!prev)" right after the gamepad
    # mappings are loaded): box64's strlcpy wrapper strncpy-pads and then
    # writes dst[size-1], i.e. it always writes `size` bytes, where real
    # strlcpy writes min(strlen(src), size-1)+1. SDL3's SDL_GetGamepadMappings
    # passes a size 7 bytes larger than the space actually left (upstream
    # precedence slip: sizeof(char*) * num + 1), so under box64 the last copy
    # clobbers the next malloc chunk header. Same for strlcat's dst[size-1].
    patches = (old.patches or []) ++ [
      (pkgs.writeText "box64-strlcpy-semantics.patch" ''
        --- a/src/wrapped/wrappedlibc.c
        +++ b/src/wrapped/wrappedlibc.c
        @@ -4989,22 +4989,27 @@
         
         EXPORT size_t my_strlcpy(x64emu_t* emu, void* dst, void* src, size_t l)
         {
        +    // strlcpy writes min(strlen(src), l-1)+1 bytes, never l bytes:
        +    // callers may pass a size larger than the space that is actually left
        +    // (e.g. SDL3 SDL_GetGamepadMappings), so padding to l corrupts the heap.
        +    size_t n = strlen(src);
             if (l > 0) {
        -        strncpy(dst, src, l-1);
        -        ((char*)dst)[l-1] = '\0';
        +        size_t c = (n < l-1) ? n : l-1;
        +        memcpy(dst, src, c);
        +        ((char*)dst)[c] = '\0';
             }
        -    return strlen(src);
        +    return n;
         }
         EXPORT size_t my_strlcat(x64emu_t* emu, void* dst, void* src, size_t l)
         {
        -    if (l == 0)
        -        return strlen(src);
        -    size_t s = strlen(dst);
        -    if(s>=l)
        -        return s + strlen(src);
        -    strncat(dst, src, l-s-1);
        -    ((char*)dst)[l-1] = '\0';
        -    return s+strlen(src);
        +    size_t n = strlen(src);
        +    size_t s = strnlen(dst, l);
        +    if (s == l)
        +        return l + n;
        +    size_t c = (n < l-s-1) ? n : l-s-1;
        +    memcpy((char*)dst+s, src, c);
        +    ((char*)dst)[s+c] = '\0';
        +    return s + n;
         }
         
         EXPORT int my_register_printf_specifier(x64emu_t* emu, int c, void* f1, void* f2)
      '')
      # SECOND ROOT CAUSE (world entry): box64 relocates every live thread's
      # TLS block when a later dlopen() (here the client's libquiche.so, Rust,
      # has TLS) pushes the total across the 64K rounding boundary. NativeAOT
      # keeps its Thread objects *in* TLS and links them from a global
      # ThreadStore, so the next GC suspension reads a freed m_hOSThread (0),
      # pthread_kill(0, SIGRTMIN) fails and PalHijack abort()s with no message.
      # Rounding to 1MB makes ordinary dlopen()s never cross a boundary.
      (pkgs.writeText "box64-tls-1mb.patch" ''
        --- a/src/emu/x64tls.c
        +++ b/src/emu/x64tls.c
        @@ -268,7 +268,14 @@
         }
         static int sizeTLSData(int s)
         {
        -    uint32_t mask = 0xffff/*BOX64ENV(nogtk)?0xffff:0x1fff*/;    // x86_64 does the mapping per 64K blocks, so it makes sense to have it this large
        +    // Round each thread's TLS block to 1MB (was 64K). When a library with a
        +    // TLS segment is dlopen()ed after threads exist, crossing the rounding
        +    // boundary makes resizeTLSData() relocate every live thread's block, which
        +    // silently invalidates any pointer into TLS: .NET NativeAOT keeps its
        +    // Thread objects in TLS and links them from a global ThreadStore, so the
        +    // next GC suspension reads a freed handle and abort()s. The surplus is
        +    // never touched, so it costs virtual address space only.
        +    uint32_t mask = 0xfffff;
             return (s+mask)&~mask;
         }

      '')
      # FOURTH ROOT CAUSE (world entry): glibc runs pthread key destructors in
      # key-creation order and box64's own per-thread key is the oldest, so at
      # guest thread exit box64 frees the emu + guest TLS block *before* the
      # guest's destructors run. NativeAOT detaches its Thread (which lives in
      # TLS) from such a destructor; run on a fresh emu, the real Thread stays
      # linked in the ThreadStore pointing into freed memory -> the next GC
      # suspension pthread_kill()s a garbage handle and abort()s, or marks the
      # dead thread's allocation context and segfaults on a fake object header.
      # Fix: box64's destructor re-arms its key once so glibc calls it again in
      # the next round, after the guest destructors.
      (pkgs.writeText "box64-thread-key-order.patch" ''
        --- a/src/include/threads.h
        +++ b/src/include/threads.h
        @@ -15,6 +15,7 @@
         	ulong_t 	hself;
         	int			cancel_cap, cancel_size;
         	void**		cancels;
        +	int			dtor_deferred;	// thread_key destructor already re-armed once (see emuthread_destroy)
         } emuthread_t;
         int get_active_emu_workers(void);
         void CleanStackSize(box64context_t* context);
        --- a/src/libtools/threads.c
        +++ b/src/libtools/threads.c
        @@ -187,6 +187,20 @@
         	emuthread_t *et = (emuthread_t*)p;
         	if(!et)
         		return;
        +	// At thread exit glibc runs pthread key destructors in key-creation order
        +	// and box64's thread_key is the oldest key of the process, so this would
        +	// free the emu -- and with it the guest TLS block -- before the guest's own
        +	// key destructors run (e.g. .NET NativeAOT detaches its Thread, which lives
        +	// in TLS, from a key destructor; running it on a fresh emu leaves a dangling
        +	// entry in its thread list and the next GC suspension aborts). glibc has
        +	// already cleared the key value when it calls a destructor, and re-runs
        +	// destructors for keys re-armed during a round, so re-arm ours once and
        +	// let the guest destructors of this round go first.
        +	if(thread_key_ready && !et->dtor_deferred && pthread_getspecific(thread_key)==NULL) {
        +		et->dtor_deferred = 1;
        +		pthread_setspecific(thread_key, et);
        +		return;
        +	}
         	#ifdef BOX32
         	if(et->is32bits && !et->join && et->fnc)
         		to_hash_d(et->self);
      '')
      # Diagnostic + safety net for the same area: log pthread_kill failures
      # (handle, signal, caller) and turn a NULL handle into ESRCH instead of
      # letting glibc dereference it with every signal blocked.
      (pkgs.writeText "box64-pthread-kill-diag.patch" ''
        --- a/src/libtools/threads.c
        +++ b/src/libtools/threads.c
        @@ -991,7 +991,16 @@
         	if(sig==0 && thread!=(void*)pthread_self())
         		return get_thread(thread)?0:ESRCH;
         	#endif
        -	return pthread_kill((pthread_t)thread, sig);
        +	// A NULL handle would make glibc dereference it with all signals blocked
        +	// (unhandleable SIGSEGV). Report it as "no such thread" instead, and say so.
        +	if(thread==NULL) {
        +		printf_log(LOG_NONE, "%04d|Warning: pthread_kill(NULL, %d) from %p -> ESRCH\n", GetTID(), sig, (void*)pthread_self());
        +		return ESRCH;
        +	}
        +	int ret = pthread_kill((pthread_t)thread, sig);
        +	if(ret && ret!=ESRCH && ret!=EAGAIN)
        +		printf_log(LOG_NONE, "%04d|Warning: pthread_kill(%p, %d) from %p returned %d\n", GetTID(), thread, sig, (void*)pthread_self(), ret);
        +	return ret;
         }

         EXPORT int my_pthread_kill_old(x64emu_t* emu, void* thread, int sig)
      '')
    ];
  });
  java = pkgs.temurin-jre-bin-25;  # native aarch64; the official bundle is Temurin 25

  # HytaleServer.jar ships its natives for linux-x64 only (native/linux-x64/
  # {libquiche,librocksdb,libzstd}.so) and its loaders throw "Unsupported
  # Linux architecture: aarch64", so the singleplayer server comes up with no
  # QUIC listener. Fix without touching the install: an overlay jar carrying
  # aarch64 builds at the *same* resource paths goes first on the classpath
  # (classpath order wins for resources) and -Dos.arch=amd64 makes the
  # loaders take the linux-x64 branch. Versions match the bundle: quiche
  # 0.29.3 (C API), RocksDB 10.x (C API), zstd 1.5.7.
  quiche = pkgs.rustPlatform.buildRustPackage rec {
    pname = "quiche";
    version = "0.29.3";
    src = pkgs.fetchCrate {
      inherit pname version;
      hash = "sha256-xADGDJzb3NQPY6AS3KZq/D9jglDRAQofUpnxYKV8zZM=";
    };
    cargoLock.lockFile = "${src}/Cargo.lock";   # crates.io package ships one, no git deps
    nativeBuildInputs = [ pkgs.cmake pkgs.perl pkgs.git pkgs.rustPlatform.bindgenHook ];  # boring-sys: cmake for BoringSSL, git init for its patch step
    dontUseCmakeConfigure = true;
    # Hytale's QuicheNative resolves every symbol eagerly. Beyond upstream's
    # ffi it needs qlog (quiche_conn_set_qlog_*), sfv
    # (quiche_h3_parse_extensible_priority) and three fork-only functions --
    # in-memory cert/key loading and optional peer verification -- which are
    # appended below (signatures recovered from the Java FunctionDescriptors).
    buildFeatures = [ "ffi" "qlog" "sfv" ];
    postPatch = ''
      cat ${pkgs.writeText "hytale-quiche-tls.rs" ''

      // ---- Hytale-fork FFI additions: in-memory certificate / private key loading
      // and "request but do not require" peer verification. Names are prefixed and
      // bound with link_name so they cannot clash with declarations above.

      #[allow(non_camel_case_types)]
      #[repr(transparent)]
      struct HY_X509 {
          _unused: c_void,
      }

      #[allow(non_camel_case_types)]
      #[repr(transparent)]
      struct HY_EVP_PKEY {
          _unused: c_void,
      }

      #[allow(non_camel_case_types)]
      #[repr(transparent)]
      struct HY_BIO {
          _unused: c_void,
      }

      extern "C" {
          #[link_name = "BIO_new_mem_buf"]
          fn hy_BIO_new_mem_buf(buf: *const c_void, len: libc::ssize_t) -> *mut HY_BIO;
          #[link_name = "BIO_free"]
          fn hy_BIO_free(bio: *mut HY_BIO) -> c_int;
          #[link_name = "PEM_read_bio_X509"]
          fn hy_PEM_read_bio_X509(
              bio: *mut HY_BIO, x: *mut *mut HY_X509, cb: *const c_void, u: *mut c_void,
          ) -> *mut HY_X509;
          #[link_name = "PEM_read_bio_PrivateKey"]
          fn hy_PEM_read_bio_PrivateKey(
              bio: *mut HY_BIO, x: *mut *mut HY_EVP_PKEY, cb: *const c_void,
              u: *mut c_void,
          ) -> *mut HY_EVP_PKEY;
          #[link_name = "d2i_X509"]
          fn hy_d2i_X509(
              out: *mut *mut HY_X509, inp: *mut *const u8, len: libc::c_long,
          ) -> *mut HY_X509;
          #[link_name = "d2i_AutoPrivateKey"]
          fn hy_d2i_AutoPrivateKey(
              out: *mut *mut HY_EVP_PKEY, inp: *mut *const u8, len: libc::c_long,
          ) -> *mut HY_EVP_PKEY;
          #[link_name = "X509_free"]
          fn hy_X509_free(x: *mut HY_X509);
          #[link_name = "EVP_PKEY_free"]
          fn hy_EVP_PKEY_free(k: *mut HY_EVP_PKEY);
          #[link_name = "SSL_CTX_use_certificate"]
          fn hy_SSL_CTX_use_certificate(ctx: *mut SSL_CTX, x: *mut HY_X509) -> c_int;
          #[link_name = "SSL_CTX_add1_chain_cert"]
          fn hy_SSL_CTX_add1_chain_cert(ctx: *mut SSL_CTX, x: *mut HY_X509) -> c_int;
          #[link_name = "SSL_CTX_use_PrivateKey"]
          fn hy_SSL_CTX_use_PrivateKey(ctx: *mut SSL_CTX, k: *mut HY_EVP_PKEY) -> c_int;
          #[link_name = "SSL_CTX_set_custom_verify"]
          fn hy_SSL_CTX_set_custom_verify(
              ctx: *mut SSL_CTX, mode: c_int,
              cb: Option<unsafe extern "C" fn(ssl: *mut SSL, out_alert: *mut u8) -> c_int>,
          );
      }

      fn hy_is_pem(data: &[u8]) -> bool {
          let start = data
              .iter()
              .position(|b| !b.is_ascii_whitespace())
              .unwrap_or(0);
          data[start..].starts_with(b"-----BEGIN")
      }

      // enum ssl_verify_result_t { ssl_verify_ok = 0, ... }
      unsafe extern "C" fn hy_verify_accept_any(_ssl: *mut SSL, _out_alert: *mut u8) -> c_int {
          0
      }

      impl Context {
          /// Certificate (chain) from memory, PEM or DER. First cert is the leaf.
          pub fn use_certificate_from_memory(&mut self, data: &[u8]) -> Result<()> {
              unsafe {
                  if hy_is_pem(data) {
                      let bio = hy_BIO_new_mem_buf(
                          data.as_ptr() as *const c_void,
                          data.len() as libc::ssize_t,
                      );
                      if bio.is_null() {
                          return Err(Error::TlsFail);
                      }
                      let mut count = 0;
                      let mut ok = true;
                      loop {
                          let x = hy_PEM_read_bio_X509(
                              bio,
                              ptr::null_mut(),
                              ptr::null(),
                              ptr::null_mut(),
                          );
                          if x.is_null() {
                              break;
                          }
                          let r = if count == 0 {
                              hy_SSL_CTX_use_certificate(self.as_mut_ptr(), x)
                          } else {
                              hy_SSL_CTX_add1_chain_cert(self.as_mut_ptr(), x)
                          };
                          hy_X509_free(x);
                          count += 1;
                          if r != 1 {
                              ok = false;
                              break;
                          }
                      }
                      hy_BIO_free(bio);
                      if ok && count > 0 {
                          Ok(())
                      } else {
                          Err(Error::TlsFail)
                      }
                  } else {
                      let mut p = data.as_ptr();
                      let x = hy_d2i_X509(ptr::null_mut(), &mut p, data.len() as libc::c_long);
                      if x.is_null() {
                          return Err(Error::TlsFail);
                      }
                      let r = hy_SSL_CTX_use_certificate(self.as_mut_ptr(), x);
                      hy_X509_free(x);
                      map_result(r)
                  }
              }
          }

          /// Private key from memory, PEM or DER (PKCS#8 or traditional).
          pub fn use_privkey_from_memory(&mut self, data: &[u8]) -> Result<()> {
              unsafe {
                  let key = if hy_is_pem(data) {
                      let bio = hy_BIO_new_mem_buf(
                          data.as_ptr() as *const c_void,
                          data.len() as libc::ssize_t,
                      );
                      if bio.is_null() {
                          return Err(Error::TlsFail);
                      }
                      let k = hy_PEM_read_bio_PrivateKey(
                          bio,
                          ptr::null_mut(),
                          ptr::null(),
                          ptr::null_mut(),
                      );
                      hy_BIO_free(bio);
                      k
                  } else {
                      let mut p = data.as_ptr();
                      hy_d2i_AutoPrivateKey(ptr::null_mut(), &mut p, data.len() as libc::c_long)
                  };
                  if key.is_null() {
                      return Err(Error::TlsFail);
                  }
                  let r = hy_SSL_CTX_use_PrivateKey(self.as_mut_ptr(), key);
                  hy_EVP_PKEY_free(key);
                  map_result(r)
              }
          }

          /// Request the peer's certificate (SSL_VERIFY_PEER) but accept the
          /// handshake regardless of it; the application inspects the cert itself.
          pub fn set_verify_peer_optional(&mut self) {
              unsafe {
                  hy_SSL_CTX_set_custom_verify(
                      self.as_mut_ptr(),
                      0x01, // SSL_VERIFY_PEER
                      Some(hy_verify_accept_any),
                  );
              }
          }
      }
      ''} >> src/tls/mod.rs
      cat ${pkgs.writeText "hytale-quiche-lib.rs" ''

      // ---- Hytale-fork additions (see tls/mod.rs).
      impl Config {
          pub fn load_cert_from_memory(&mut self, data: &[u8]) -> Result<()> {
              self.tls_ctx.use_certificate_from_memory(data)
          }

          pub fn load_priv_key_from_memory(&mut self, data: &[u8]) -> Result<()> {
              self.tls_ctx.use_privkey_from_memory(data)
          }

          pub fn verify_peer_optional(&mut self) {
              self.tls_ctx.set_verify_peer_optional();
          }
      }
      ''} >> src/lib.rs
      cat ${pkgs.writeText "hytale-quiche-ffi.rs" ''

      // ---- Hytale-fork FFI: signatures recovered from the Java binding
      // (FunctionDescriptor.of(C_INT, C_POINTER, C_POINTER, C_LONG) and
      // ofVoid(C_POINTER)).
      #[no_mangle]
      pub extern "C" fn quiche_config_load_cert(
          config: &mut Config, buf: *const u8, len: size_t,
      ) -> c_int {
          let data = unsafe { slice::from_raw_parts(buf, len) };

          match config.load_cert_from_memory(data) {
              Ok(_) => 0,

              Err(e) => e.to_c() as c_int,
          }
      }

      #[no_mangle]
      pub extern "C" fn quiche_config_load_priv_key(
          config: &mut Config, buf: *const u8, len: size_t,
      ) -> c_int {
          let data = unsafe { slice::from_raw_parts(buf, len) };

          match config.load_priv_key_from_memory(data) {
              Ok(_) => 0,

              Err(e) => e.to_c() as c_int,
          }
      }

      #[no_mangle]
      pub extern "C" fn quiche_config_verify_peer_optional(config: &mut Config) {
          config.verify_peer_optional();
      }
      ''} >> src/ffi.rs
    '';
    doCheck = false;
    installPhase = ''
      mkdir -p $out/lib
      find target -name libquiche.so -exec cp {} $out/lib/ \;
      cp -r include $out/
    '';
  };
  serverNatives = pkgs.runCommand "hytale-server-natives-aarch64.jar" {
    nativeBuildInputs = [ pkgs.zip ];
  } ''
    mkdir -p native/linux-x64
    cp ${quiche}/lib/libquiche.so                    native/linux-x64/libquiche.so
    cp ${lib.getLib pkgs.rocksdb}/lib/librocksdb.so  native/linux-x64/librocksdb.so
    cp ${lib.getLib pkgs.zstd}/lib/libzstd.so        native/linux-x64/libzstd.so
    chmod 644 native/linux-x64/*
    zip -0 -r $out native   # stored, not deflated: keeps the RUNPATH store references scannable
  '';
  # What the client gets as --java-exec: turns `java <jvm opts> -jar X <args>`
  # into a classpath launch with the overlay first. Enable-Native-Access from
  # the manifest must be restated once -jar is gone.
  serverJava = pkgs.writeShellScript "hytale-server-java" ''
    orig=("$@"); pre=(); post=(); jar=""
    while (($#)); do
      if [[ -z $jar && $1 == -jar ]]; then jar=$2; shift 2; continue; fi
      if [[ -z $jar ]]; then pre+=("$1"); else post+=("$1"); fi
      shift
    done
    [[ -n $jar ]] || exec ${java}/bin/java "''${orig[@]}"
    main=$(${pkgs.unzip}/bin/unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' | sed -n 's/^Main-Class: //p')
    # The third-party natives in the jar (Netty QUIC, zstd-jni, JLine) DO ship
    # aarch64 builds, but their loaders pick the resource by os.arch, which we
    # spoof. All of them fall back to java.library.path, so extract the aarch64
    # files into a per-jar directory (keyed by the jar's hash: survives game
    # updates) and serve them from there. Netty additionally derives the file
    # *name* from os.arch, hence the rename.
    ov=''${XDG_CACHE_HOME:-$HOME/.cache}/hytale/server/$(${pkgs.coreutils}/bin/sha256sum "$jar" | cut -c1-16)/lib
    if [[ ! -e $ov/.ready ]]; then
      rm -rf "$ov"; mkdir -p "$ov"
      ${pkgs.unzip}/bin/unzip -o -q -j "$jar" \
        'META-INF/native/libnetty_quiche42_linux_aarch_64.so' 'linux/aarch64/*' 'org/jline/nativ/Linux/arm64/*' \
        -d "$ov" 2>/dev/null || true
      [[ -e $ov/libnetty_quiche42_linux_aarch_64.so ]] && \
        mv "$ov/libnetty_quiche42_linux_aarch_64.so" "$ov/libnetty_quiche42_linux_x86_64.so"
      touch "$ov/.ready"
    fi
    # os.arch=amd64 steers Hytale's loaders to native/linux-x64, but the JDK's
    # FFM linker also derives its calling convention from os.arch (CABI.java),
    # which would emit x86-64 SysV downcall stubs on this aarch64 VM -> SIGSEGV
    # on the first foreign call (jline's isatty). Pin the ABI explicitly.
    exec ${java}/bin/java "''${pre[@]}" -Dos.arch=amd64 -Djdk.internal.foreign.CABI=LINUX_AARCH_64 \
      -Djava.library.path="$ov" --enable-native-access=ALL-UNNAMED \
      -cp "${serverNatives}:$jar" "''${main:-com.hypixel.hytale.Main}" "''${post[@]}"
  '';

  # x86_64 userland for the launcher, straight from cache.nixos.org. The FEX
  # Ubuntu image has GTK3 but no libwebkit2gtk-4.1 (FEX-Emu/RootFS
  # Configs/Ubuntu_24_04.json), and nix x86 libs can't be mixed into it
  # (glibc 2.42 vs 2.39). Keep nixpkgs-fex on nixos-unstable so every one of
  # these is a cache hit; nothing here is ever built locally.
  pkgsx86 = import inputs.nixpkgs-fex { system = "x86_64-linux"; };
  x86Libs = pkgs.buildEnv {
    name = "hytale-launcher-x86-libs";
    # DT_NEEDED + dlopen set of the launcher (same set the community FHS
    # flakes patchelf against); transitive deps resolve through nix RUNPATHs.
    paths = map lib.getLib (with pkgsx86; [
      glibc gcc.cc.lib
      gtk3 webkitgtk_4_1 glib glib-networking libsoup_3
      pango cairo gdk-pixbuf harfbuzz freetype fontconfig at-spi2-core dbus
      libglvnd mesa libdrm libxkbcommon wayland
      xorg.libX11 xorg.libXcomposite xorg.libXdamage xorg.libXext xorg.libXfixes
      xorg.libXrandr xorg.libXrender xorg.libXi xorg.libXcursor xorg.libXinerama
      xorg.libXtst xorg.libxshmfence
      alsa-lib libpulseaudio nss nspr openssl expat cups zlib
    ]);
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };
  schemaDirs = with pkgsx86; "${gtk3}/share/gsettings-schemas/${gtk3.name}:${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}";

  # FEX RootFS for the launcher: the ELF interpreter, plus passthrough links
  # so `#!` scripts resolve. FEX looks a shebang interpreter up *only* under
  # the RootFS (GetShebangInterpFile) and returns ENOEXEC otherwise, which
  # would break xdg-open (browser login) and any /nix/store/... script.
  # x86 userland for the client under FEX (HYTALE_CLIENT_EMU=fex): the same
  # nixpkgs approach as the launcher, so it shares the launcher's loader-only
  # RootFS and FEXServer (a second FEXServer is impossible while ~/.fex-emu
  # exists: FEX prefers that legacy data dir over FEX_APP_DATA_LOCATION and
  # allows one server per data dir). Deliberately WITHOUT libGL/libvulkan:
  # those come from FEX's thunks, which overlay RootFS paths (see fexRootfs),
  # and a copy on LD_LIBRARY_PATH would shadow them with emulated llvmpipe.
  clientX86Libs = pkgs.buildEnv {
    name = "hytale-client-x86-libs";
    paths = map lib.getLib (with pkgsx86; [
      glibc gcc.cc.lib
      icu openssl zlib expat dbus udev
      xorg.libX11 xorg.libXext xorg.libXcursor xorg.libXi xorg.libXrandr xorg.libXfixes
      xorg.libXrender xorg.libXinerama xorg.libXScrnSaver xorg.libXxf86vm
      xorg.libXcomposite xorg.libXdamage xorg.libxshmfence xorg.libxcb
      libxkbcommon wayland libdecor
      alsa-lib libpulseaudio libogg libvorbis libopus libpng libjpeg
      libbsd libunwind
    ]);
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };

  # FEX's guest thunk libraries under the sonames the client asks for, as
  # regular files (FEX re-resolves absolute RootFS symlinks inside the RootFS,
  # which is why the RootFS decoys below were never reached). First on the
  # guest LD_LIBRARY_PATH -> GL/Vulkan go to the host driver, no overlay needed.
  fexGuestThunks = pkgs.runCommand "hytale-fex-guest-thunks" {
    nativeBuildInputs = [ pkgs.patchelf ];
  } ''
    mkdir -p $out/lib
    cp ${fex}/share/fex-emu/GuestThunks/libGL-guest.so      $out/lib/libGL.so.1
    cp ${fex}/share/fex-emu/GuestThunks/libGL-guest.so      $out/lib/libGL.so
    cp ${fex}/share/fex-emu/GuestThunks/libEGL-guest.so     $out/lib/libEGL.so.1
    cp ${fex}/share/fex-emu/GuestThunks/libvulkan-guest.so  $out/lib/libvulkan.so.1
    cp ${fex}/share/fex-emu/GuestThunks/libwayland-client-guest.so $out/lib/libwayland-client.so.0
    chmod u+w $out/lib/*
    # The thunks reference __gxx_personality_v0 without depending on libstdc++
    # (a stock guest has it loaded globally already); declare it, the guest
    # x86 libstdc++ is on LD_LIBRARY_PATH via clientX86Libs.
    for f in $out/lib/*; do
      patchelf --add-needed libstdc++.so.6 --add-needed libgcc_s.so.1 "$f"
    done
  '';

  # Control for HYTALE_FEX_THUNKS=0: emulated x86 Mesa (llvmpipe), no thunks.
  clientX86GL = pkgs.buildEnv {
    name = "hytale-client-x86-gl";
    paths = map lib.getLib (with pkgsx86; [ libglvnd mesa libdrm ]);
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };

  # Diagnostic (HYTALE_FEX_STACKCHK=1): x86_64 shim preloaded into the guest
  # that turns glibc's silent "*** stack smashing detected ***" into a guest
  # backtrace on stderr (-> fex-client.log) before aborting. Built with the
  # same cross clang the nixpkgs FEX package uses for its guest thunks.
  x86StackChk = pkgs.runCommand "hytale-x86-stackchk" {
    nativeBuildInputs = [ pkgs.pkgsCross.gnu64.buildPackages.clang ];
  } ''
    mkdir -p $out/lib
    cat > shim.c <<'EOF'
    #define _GNU_SOURCE
    #include <execinfo.h>
    #include <stdlib.h>
    #include <unistd.h>
    #include <stdio.h>
    #include <sys/syscall.h>
    #include <errno.h>
    #include <sys/uio.h>
    #include <string.h>
    #include <pthread.h>
    /* __stack_chk_fail is reached by `sub rax, fs:[0x28]; jne` in the caller, so
       on entry rax == frame_canary - tls_canary. A naked asm entry saves rax
       and the caller's rsp before C code can touch them. */
    void hy_stack_chk_fail_c(unsigned long hy_diff, unsigned long hy_callsp);
    __asm__(".globl __stack_chk_fail\n.type __stack_chk_fail,@function\n__stack_chk_fail:\n"
            "  mov %rax, %rdi\n"
            "  mov %rsp, %rsi\n"
            "  jmp hy_stack_chk_fail_c\n");
    void hy_stack_chk_fail_c(unsigned long hy_diff, unsigned long hy_callsp) {
      void* bt[64];
      int n = backtrace(bt, 64);
      unsigned long tls_canary; __asm__("mov %%fs:0x28, %0" : "=r"(tls_canary));
      unsigned long tcb; __asm__("mov %%fs:0, %0" : "=r"(tcb));
      char msg[256];
      int l = snprintf(msg, sizeof msg, "*** stack smashing detected (guest, %d frames) tid=%ld ***\n"
                       "    tls canary=%#lx frame canary=%#lx (diff %#lx) tcb=%#lx pthread_self=%#lx\n",
                       n, (long)syscall(186), tls_canary, tls_canary + hy_diff, hy_diff, tcb, (unsigned long)pthread_self());
      write(2, msg, l);
      /* The smashed frame lies just above our return address: dump it. */
      unsigned long* sp = (unsigned long*)hy_callsp;
      for (int i = 0; i < 40; i += 4) {
        l = snprintf(msg, sizeof msg, "    [ret+%03x] %016lx %016lx %016lx %016lx\n", i * 8, sp[i], sp[i+1], sp[i+2], sp[i+3]);
        write(2, msg, l);
      }
      backtrace_symbols_fd(bt, n, 2);
      abort();
    }
    /* Guest-side SIGSEGV/SIGBUS reporter: NativeAOT only handles faults in
       managed code and chains to the previous handler otherwise, so this runs
       for native faults. Prints guest RIP, fault address and a backtrace, then
       restores SIG_DFL and returns to re-fault (dump as usual). */
    #include <signal.h>
    #include <ucontext.h>
    #include <fcntl.h>
    #include <dlfcn.h>
    static void hy_fault(int sig, siginfo_t* si, void* uc) {
      ucontext_t* u = (ucontext_t*)uc;
      greg_t* g = u->uc_mcontext.gregs;
      char msg[512];
      int l = snprintf(msg, sizeof msg, "*** guest signal %d at rip=%#llx addr=%p code=%d ***\n",
                       sig, (unsigned long long)g[REG_RIP], si->si_addr, si->si_code);
      write(2, msg, l);
      /* Attribute RIP and code-looking stack values without dladdr (takes
         loader locks): scan /proc/thread-self/maps with raw syscalls. */
      {
        static char buf[1 << 17]; ssize_t n = -1;
        int fd = syscall(257, -100, "/proc/thread-self/maps", O_RDONLY, 0);
        if (fd >= 0) { n = read(fd, buf, sizeof buf - 1); close(fd); }
        if (n > 0) {
          buf[n] = 0;
          unsigned long long* sp = (unsigned long long*)g[REG_RSP];
          unsigned long long want[17]; int nw = 0;
          want[nw++] = (unsigned long long)g[REG_RIP];
          for (int i = 0; i < 16; i++) want[nw++] = sp[i];
          for (int w = 0; w < nw; w++) {
            unsigned long long v = want[w];
            if (v < 0x10000ULL) continue;
            char* line = buf;
            while (line && *line) {
              char* nl = strchr(line, '\n'); if (nl) *nl = 0;
              unsigned long long lo = 0, hi = 0, off = 0; char perms[8] = {0}; char path[256] = {0};
              int k = sscanf(line, "%llx-%llx %7s %llx %*s %*s %255s", &lo, &hi, perms, &off, path);
              if (k >= 4 && v >= lo && v < hi) {
                if (perms[2] == 'x') {
                  l = snprintf(msg, sizeof msg, "    %s %#llx = %s + %#llx\n", w == 0 ? "rip  " : "stack", v, path[0] ? path : "?", v - lo + off);
                  write(2, msg, l);
                }
                if (nl) *nl = '\n';
                break;
              }
              if (nl) *nl = '\n';
              line = nl ? nl + 1 : 0;
            }
          }
        }
      }
      l = snprintf(msg, sizeof msg, "    rax=%#llx rbx=%#llx rcx=%#llx rdx=%#llx rsi=%#llx rdi=%#llx rbp=%#llx rsp=%#llx r8=%#llx r9=%#llx r12=%#llx r14=%#llx\n",
                   (unsigned long long)g[REG_RAX], (unsigned long long)g[REG_RBX], (unsigned long long)g[REG_RCX], (unsigned long long)g[REG_RDX],
                   (unsigned long long)g[REG_RSI], (unsigned long long)g[REG_RDI], (unsigned long long)g[REG_RBP], (unsigned long long)g[REG_RSP],
                   (unsigned long long)g[REG_R8], (unsigned long long)g[REG_R9], (unsigned long long)g[REG_R12], (unsigned long long)g[REG_R14]);
      write(2, msg, l);
      unsigned char* ip = (unsigned char*)g[REG_RIP];
      if ((unsigned long long)ip >= 4096) {
        l = snprintf(msg, sizeof msg, "    bytes: %02x %02x %02x %02x %02x %02x %02x %02x\n", ip[0],ip[1],ip[2],ip[3],ip[4],ip[5],ip[6],ip[7]);
        write(2, msg, l);
      }
      unsigned long long* sp = (unsigned long long*)g[REG_RSP];
      l = snprintf(msg, sizeof msg, "    stack: [rsp]=%#llx [rsp+8]=%#llx [rsp+16]=%#llx [rsp+24]=%#llx\n", sp[0], sp[1], sp[2], sp[3]);
      write(2, msg, l);
      void* bt[48]; int n = backtrace(bt, 48); backtrace_symbols_fd(bt, n, 2);
      signal(sig, SIG_DFL);
    }
    /* Background recorder: every few seconds write the guest loader's object
       list (dl_iterate_phdr: base + PT_LOAD ranges + name, incl. dlopen'd
       libs) and the guest's view of /proc/self/maps to
       $HOME/.cache/hytale/guest-objects.txt, so a crash RIP in a mapping the
       host cannot name can be attributed afterwards. */
    #include <link.h>
    #include <pthread.h>
    static int hy_phdr_cb(struct dl_phdr_info* info, size_t sz, void* data) {
      FILE* f = data; (void)sz;
      for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr)* ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD) continue;
        unsigned long lo = info->dlpi_addr + ph->p_vaddr, hi = lo + ph->p_memsz;
        fprintf(f, "%#lx-%#lx %c%c%c base=%#lx off=%#lx %s\n", lo, hi,
                (ph->p_flags & PF_R) ? 'r' : '-', (ph->p_flags & PF_W) ? 'w' : '-', (ph->p_flags & PF_X) ? 'x' : '-',
                (unsigned long)info->dlpi_addr, (unsigned long)ph->p_offset, info->dlpi_name && *info->dlpi_name ? info->dlpi_name : "(main)");
      }
      return 0;
    }
    static void* hy_recorder(void* arg) {
      (void)arg;
      char path[512]; const char* home = getenv("HOME");
      snprintf(path, sizeof path, "%s/.cache/hytale/guest-objects.txt", home ? home : "/tmp");
      for (;;) {
        char tmp[520]; snprintf(tmp, sizeof tmp, "%s.tmp", path);
        FILE* (*real_fopen)(const char*, const char*) = dlsym(RTLD_NEXT, "fopen");
        FILE* f = real_fopen(tmp, "w");
        if (f) {
          fprintf(f, "## dl_iterate_phdr\n");
          dl_iterate_phdr(hy_phdr_cb, f);
          fprintf(f, "## /proc/self/maps (guest view)\n");
          int fd = syscall(257, -100, "/proc/self/maps", O_RDONLY, 0);
          if (fd >= 0) { char b[4096]; ssize_t n; while ((n = read(fd, b, sizeof b)) > 0) fwrite(b, 1, n, f); close(fd); }
          fclose(f); rename(tmp, path);
        }
        sleep(3);
      }
      return 0;
    }
    __attribute__((constructor)) static void hy_install(void) {
      void* warm[4]; backtrace(warm, 4);   /* first backtrace() dlopens libgcc: do it now, not in a handler */
      pthread_t t; pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
      pthread_create(&t, &a, hy_recorder, 0);
      struct sigaction sa; memset(&sa, 0, sizeof sa);
      sa.sa_sigaction = hy_fault; sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
      sigaction(SIGSEGV, &sa, 0); sigaction(SIGBUS, &sa, 0);
    }
    /* HYTALE_FEX_NOMODSCAN=1: starve sentry-native's module finder. It starts
       from /proc/self/maps and then mmaps/munmaps every module's ELF file to
       read build-ids; under an emulator those unmaps hit the emulator's own
       code-tracking for live libraries. glibc reads the file once at startup
       (main-thread stack bounds), so the first 20 s stay allowed. */
    #include <time.h>
    #include <stdarg.h>
    static time_t hy_t0;
    static int hy_deny_maps(const char* path) {
      if (!getenv("HYTALE_FEX_NOMODSCAN") || !path || strcmp(path, "/proc/self/maps") != 0) return 0;
      if (!hy_t0) hy_t0 = time(0);
      return time(0) - hy_t0 > 20;
    }
    int open(const char* path, int flags, ...) {
      mode_t mode = 0;
      if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
      if (hy_deny_maps(path)) { errno = ENOENT; return -1; }
      return syscall(257 /* openat */, -100 /* AT_FDCWD */, path, flags, mode);
    }
    int open64(const char* path, int flags, ...) {
      mode_t mode = 0;
      if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
      if (hy_deny_maps(path)) { errno = ENOENT; return -1; }
      return syscall(257, -100, path, flags, mode);
    }
    FILE* fopen(const char* path, const char* mode) {
      if (hy_deny_maps(path)) { errno = ENOENT; return 0; }
      FILE* (*real)(const char*, const char*) = dlsym(RTLD_NEXT, "fopen");
      return real(path, mode);
    }
    FILE* fopen64(const char* path, const char* mode) {
      if (hy_deny_maps(path)) { errno = ENOENT; return 0; }
      FILE* (*real)(const char*, const char*) = dlsym(RTLD_NEXT, "fopen64");
      return real(path, mode);
    }
    /* HYTALE_FEX_NOVMREAD=1: make sentry-native's module reader use its memcpy
       fallback instead of a syscall a GC signal can interrupt. */
    ssize_t process_vm_readv(pid_t pid, const struct iovec* l, unsigned long ln,
                             const struct iovec* r, unsigned long rn, unsigned long f) {
      (void)pid; (void)ln; (void)rn; (void)f; (void)l; (void)r;
      if (getenv("HYTALE_FEX_NOVMREAD")) { errno = EPERM; return -1; }
      return syscall(310 /* __NR_process_vm_readv x86_64 */, pid, l, ln, r, rn, f);
    }
    EOF
    x86_64-unknown-linux-gnu-clang -shared -fPIC -O1 -fno-stack-protector -o $out/lib/libstackchk.so shim.c -ldl -lpthread
  '';

  fexRootfs = pkgs.runCommand "hytale-fex-rootfs" { } ''
    mkdir -p $out/lib64 $out/bin $out/usr/bin $out/usr/lib/x86_64-linux-gnu
    cp ${pkgsx86.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/
    ln -s /nix $out/nix
    ln -s /bin/sh $out/bin/sh
    ln -s /bin/bash $out/bin/bash
    ln -s /usr/bin/env $out/usr/bin/env
    # Thunk decoys: FEX's ThunksDB overlays these exact RootFS paths with its
    # guest thunk libraries (Data/ThunksDB.json, @PREFIX_LIB@), forwarding GL
    # and Vulkan to the host driver. The targets only matter with thunks off.
    for l in libGL.so.1 libGL.so; do
      ln -s ${lib.getLib pkgsx86.libglvnd}/lib/libGL.so.1 $out/usr/lib/x86_64-linux-gnu/$l
    done
    ln -s ${lib.getLib pkgsx86.vulkan-loader}/lib/libvulkan.so.1 $out/usr/lib/x86_64-linux-gnu/libvulkan.so.1
  '';

  # Host (aarch64) libs box64 may wrap natively. Kept to what *must* be native
  # for a coherent GPU path: the Vulkan/GL loaders and the X11 stack they get
  # their Display*/xcb connection from. NixOS has no /usr/lib, so without this
  # box64 would fall back to x86 mesa from the Ubuntu tree (no Adreno).
  # Everything else (udev, dbus, xkbcommon, audio, fontconfig...) is emulated
  # from the Ubuntu tree on purpose: SDL_Init through box64's wrappers for the
  # Wayland stack / udev / dbus corrupted the host heap ("double free or
  # corruption (!prev)"), and emulated copies talk to the same sockets fine.
  hostLibs = pkgs.buildEnv {
    name = "hytale-box64-host-libs";
    paths = map lib.getLib (with pkgs; [
      vulkan-loader libglvnd mesa libgbm libdrm
      xorg.libX11 xorg.libXext xorg.libXcursor xorg.libXi xorg.libXrandr xorg.libXfixes
      xorg.libXrender xorg.libXinerama xorg.libXScrnSaver xorg.libXxf86vm
      xorg.libXcomposite xorg.libXdamage xorg.libxshmfence xorg.libxcb
    ]);
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };

  # Ubuntu 24.04 tree, unpacked and immutable: x86 libs for the box64 client
  # (proven mode: emulated Ubuntu libssl/libcrypto/libstdc++) and the RootFS
  # for HYTALE_CLIENT_EMU=fex. Same URL/hash as fex.nix -> the .sqsh dedups.
  rootfsImage = pkgs.fetchurl {
    name = "Ubuntu_24_04.sqsh";
    url = "https://rootfs.fex-emu.gg/Ubuntu_24_04/2026-08-11/Ubuntu_24_04.sqsh";
    hash = "sha256-KFSwbT/xuPblJhNb+23Vt7MKs6tz55rpM6PZ/tlZoXg=";
  };
  # The client is NativeAOT with System.Globalization.Invariant baked in as
  # false, so the env var is ignored and it fail-fasts without ICU. The FEX
  # image ships no libicu; add Ubuntu's (release pocket = immutable URL).
  libicu74 = pkgs.fetchurl {
    url = "http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu74_74.2-1ubuntu3_amd64.deb";
    hash = "sha256-0pyXoho+MlRzHPrBhuTU5hHl5n0smgQw9qz72ayu+i4=";
  };
  # The client's bundled libopenal.so needs libatomic.so.1 (GCC's atomics
  # library), also absent from the FEX image.
  libatomic1 = pkgs.fetchurl {
    url = "http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-14/libatomic1_14-20240412-0ubuntu1_amd64.deb";
    hash = "sha256-9JbYBibhUSRWJzll1E9HsoHt9T+ibQ2L0N78W+fkYBw=";
  };
  ubuntuRootfs = pkgs.runCommand "hytale-rootfs-ubuntu-24.04" {
    nativeBuildInputs = [ pkgs.squashfsTools pkgs.dpkg ];
  } ''
    unsquashfs -quiet -no-xattrs -ignore-errors -no-exit-code -d $out ${rootfsImage}
    dpkg-deb -x ${libicu74} $out
    dpkg-deb -x ${libatomic1} $out
  '';
  ubuntuLibs = "${ubuntuRootfs}/lib/x86_64-linux-gnu:${ubuntuRootfs}/usr/lib/x86_64-linux-gnu";

  # Seed only. The launcher self-updates into ~/.local/share/Hytale and the
  # wrapper prefers that copy. Version + sha256 (hex -> SRI) from
  # https://launcher.hytale.com/version/release/launcher.json
  launcherVersion = "2026.08.28-3d62362";
  launcherSeed = pkgs.stdenvNoCC.mkDerivation {
    pname = "hytale-launcher-seed";
    version = launcherVersion;
    src = pkgs.fetchurl {
      url = "https://launcher.hytale.com/builds/release/linux/amd64/hytale-launcher-${launcherVersion}.zip";
      hash = "sha256-DLFvaRSfwilOkkdOz4rcnmsQTFQZvtIITmFBfhV67hg=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";
    dontFixup = true; # x86_64 ELF: no strip/patchelf on aarch64
    installPhase = ''
      mkdir -p $out
      cp -r ./* $out/
      rm -f $out/env-vars
      chmod +x $out/hytale-launcher
    '';
  };

  # Private FEX config namespace. SetupClient() takes the RootFS from
  # whichever FEXServer answers <uid>.FEXServer.Socket -- Steam's, if it is
  # running -- so Hytale gets its own socket name and therefore its own server.
  fexConfigDir = pkgs.linkFarm "hytale-fex-config" [
    {
      name = "Config.json";
      path = pkgs.writeText "hytale-fex-Config.json" (builtins.toJSON {
        Config = {
          RootFS = "${fexRootfs}";
          ServerSocketPath = "hytale.FEXServer.Socket";
        };
        ThunksDB = { };
      });
    }
    {
      # Only reached with HYTALE_CLIENT_EMU=fex: host GL (the client renders
      # OpenGL 4.6 through SDL3/GLX) and Vulkan through FEX's thunks.
      name = "AppConfig/HytaleClient.json";
      path = pkgs.writeText "hytale-fex-HytaleClient.json" (builtins.toJSON {
        Config = { };
        ThunksDB = { GL = 1; EGL = 1; Vulkan = 1; WaylandClient = 1; };
      });
    }
  ];

  # binfmt hook (see fex-binfmt in fex.nix). Every x86 exec in a process tree
  # that carries FEX_BINFMT_HOOK lands here (launcher updater, WebKit helper
  # processes, HytaleClient). Only HytaleClient is redirected; everything else
  # goes to FEX with argv and env untouched, so the launcher's tree is never
  # modified and wharf patching always sees the official binaries.
  hook = pkgs.writeShellScript "hytale-binfmt-hook" ''
    # argv: <pathname passed to execve> <original argv[0]> <args...>
    target=$(${pkgs.coreutils}/bin/readlink -f "/proc/$$/fd/''${FEX_EXECVEFD:-0}" 2>/dev/null || printf '%s' "$1")
    case $target in
      */Hytale/install/*/package/game/*/Client/HytaleClient) ;;
      *) exec ${fex}/bin/FEX "$@" ;;
    esac

    # Launcher passes `--java-exec <its x86 JRE>`; swap in the native one.
    args=(); next_is_java=0
    for a in "''${@:3}"; do
      if (( next_is_java )); then args+=("${serverJava}"); next_is_java=0; continue; fi
      [[ $a == --java-exec ]] && next_is_java=1
      args+=("$a")
    done

    # Launcher-only (nix x86 userland / WebKitGTK) knobs must not reach the game.
    unset LD_LIBRARY_PATH GIO_EXTRA_MODULES GDK_PIXBUF_MODULE_FILE __EGL_VENDOR_LIBRARY_FILENAMES \
          GDK_BACKEND LIBGL_ALWAYS_SOFTWARE WEBKIT_DISABLE_COMPOSITING_MODE WEBKIT_DISABLE_DMABUF_RENDERER \
          WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS NO_AT_BRIDGE

    case ''${HYTALE_CLIENT_EMU:-fex} in
      fex)
        # Same loader-only RootFS and FEXServer as the launcher; the userland
        # is nixpkgs x86_64 on LD_LIBRARY_PATH (see clientX86Libs), GL/Vulkan
        # via thunks (AppConfig/HytaleClient.json + RootFS decoys).
        # HYTALE_FEX_VIDEO=x11|wayland (default x11: GL thunk over GLX);
        # HYTALE_FEX_THUNKS=0 -> emulated x86 Mesa/llvmpipe, no thunks (control).
        if [[ ''${HYTALE_FEX_THUNKS:-1} != 0 ]]; then
          export LD_LIBRARY_PATH=${fexGuestThunks}/lib:${clientX86Libs}/lib:/usr/lib/x86_64-linux-gnu
        else
          export LD_LIBRARY_PATH=${clientX86GL}/lib:${clientX86Libs}/lib
          export LIBGL_ALWAYS_SOFTWARE=1 LIBGL_DRIVERS_PATH=${lib.getLib pkgsx86.mesa}/lib/dri __GLX_VENDOR_LIBRARY_NAME=mesa
        fi
        v=''${HYTALE_FEX_VIDEO:-x11}
        export SDL_VIDEO_DRIVER=$v SDL_VIDEODRIVER=$v
        # HalfBarrierTSOAlways (see the fex override): 1 = every scalar TSO
        # access as ldur/stur+dmb up front (no SIGBUS backpatching; slower).
        # Stock behaviour (0) is safe again with the signal fixes in place.
        export FEX_HALFBARRIERTSOALWAYS=''${FEX_HALFBARRIERTSOALWAYS:-0}
        # NativeAOT GC suspension must not need register edits to the signal
        # context (FEX drops those for signals landing in JIT code):
        # conservative stack reporting + in-place suspension. Required.
        export DOTNET_gcConservative=''${DOTNET_gcConservative:-1}
        # Every GC stops the world by signalling all threads, and a signal is
        # expensive under FEX (frame setup, state spill, sigreturn). A 512 MB
        # gen0 budget means far fewer collections for a modest memory cost.
        export DOTNET_GCgen0size=''${DOTNET_GCgen0size:-0x20000000}
        # Guest-only preload (FEX's own aarch64 ld.so just warns and ignores it).
        [[ ''${HYTALE_FEX_STACKCHK:-0} == 1 ]] && export LD_PRELOAD=${x86StackChk}/lib/libstackchk.so
        # Same per-run stderr capture as the box64 branch (launcher swallows it).
        log=''${XDG_CACHE_HOME:-$HOME/.cache}/hytale/fex-client.log
        exec ${fex}/bin/FEX "$1" "$2" "''${args[@]}" 2>"$log" ;;
      *)
        # HYTALE_HOSTLIBS=0 -> no native wrapping at all (diagnostic; no GPU).
        [[ ''${HYTALE_HOSTLIBS:-1} != 0 ]] && export LD_LIBRARY_PATH=${hostLibs}/lib:/run/opengl-driver/lib
        export SDL_VIDEO_DRIVER=x11 SDL_VIDEODRIVER=x11   # see hostLibs
        # .NET assumes x86 TSO; box64 only turns strong-memory emulation on by
        # itself for Mono/Unity/JVM. Without it the host glibc heap tears
        # ("corrupted size vs. prev_size", "double free") right after SDL_Init,
        # identically in the interpreter. 1..3 = increasingly strict/slow;
        # override from the shell: BOX64_DYNAREC_STRONGMEM=2 hytale
        export BOX64_DYNAREC_STRONGMEM=''${BOX64_DYNAREC_STRONGMEM:-1}
        export BOX64_ARG0=$2 BOX64_LOG=''${BOX64_LOG:-1} BOX64_SHOWBT=1   # BOX64_LOG=2 hytale -> every wrapped call
        exec {FEX_EXECVEFD}>&-
        unset FEX_EXECVEFD
        # The launcher swallows the child's stderr; keep box64's own log (per run).
        # At LOG=2 the hot trivial calls are dropped on the way to disk.
        log=''${XDG_CACHE_HOME:-$HOME/.cache}/hytale/box64-client.log
        if [[ $BOX64_LOG -ge 2 ]]; then
          exec ${box64}/bin/box64 "$target" "''${args[@]}" 2> >(${pkgs.gnugrep}/bin/grep --line-buffered -v -E \
            'Calling (strlen|strchr|strchrnul|memcpy|memmove|memcmp|memset|strcmp|strncmp|clock_gettime|gettimeofday|sched_yield|pthread_mutex_(un)?lock|pthread_cond|getenv|__errno_location|malloc|calloc|realloc|free|__memcpy_chk|__vsnprintf_chk|snprintf|strtod|strtol)\(|libicu' > "$log")
        else
          exec ${box64}/bin/box64 "$target" "''${args[@]}" 2>"$log"
        fi ;;
    esac
  '';

  hytale = pkgs.writeShellApplication {
    name = "hytale";
    runtimeInputs = [ pkgs.coreutils pkgs.xdg-utils ];
    text = ''
      data=''${XDG_DATA_HOME:-$HOME/.local/share}/Hytale
      cache=''${XDG_CACHE_HOME:-$HOME/.cache}/hytale
      mkdir -p "$cache/fex" "$cache/box64" "$data/tmp"

      # Go, GnuTLS (glib-networking) and OpenSSL-under-.NET all honour this;
      # the Ubuntu OpenSSL default (/usr/lib/ssl) does not exist here.
      export SSL_CERT_FILE=''${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}
      # Patch staging on the same filesystem as the install (not tmpfs /tmp).
      export TMPDIR=$data/tmp

      # Prefer the launcher's self-updated copy over the Nix seed
      # (glob order == date-version order).
      launcher=${launcherSeed}/hytale-launcher
      for l in "$data"/install/release/package/launcher/*/hytale-launcher; do
        [[ -x $l ]] && launcher=$l
      done

      # The old design swapped shims into the game tree; a leftover there
      # shows up as "exec format error" from the launcher. Warn early.
      c=$data/install/release/package/game/latest/Client/HytaleClient
      if [[ -e $c && $(head -c 4 "$c" 2>/dev/null) != $'\x7fELF' ]]; then
        echo "hytale: $c is not an ELF (leftover shim?) - restore it or rm -rf .../package/game" >&2
      fi

      # FEX: private config dir (own RootFS + own FEXServer), private code cache.
      export FEX_APP_CONFIG_LOCATION=${fexConfigDir}/
      export FEX_APP_CACHE_LOCATION=$cache/fex/
      export FEX_BINFMT_HOOK=${hook}
      export HYTALE_CLIENT_EMU=''${HYTALE_CLIENT_EMU:-fex}   # fex (default, playable) | box64 (world entry still broken)

      # Launcher (Wails/WebKitGTK) on the nix x86 userland. nix ld.so has no
      # /usr/lib search path, so its libs come through LD_LIBRARY_PATH; the
      # hook drops it again before the game. Native children (xdg-open) skip
      # the foreign-arch entries harmlessly.
      export LD_LIBRARY_PATH=${x86Libs}/lib
      export XDG_DATA_DIRS=${schemaDirs}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
      export GIO_EXTRA_MODULES=${pkgsx86.glib-networking}/lib/gio/modules
      export GDK_PIXBUF_MODULE_FILE=${pkgsx86.gdk-pixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
      export __EGL_VENDOR_LIBRARY_FILENAMES=${pkgsx86.mesa}/share/glvnd/egl_vendor.d/50_mesa.json
      unset GTK_MODULES GTK_IM_MODULE GTK_PATH GTK_EXE_PREFIX
      export NO_AT_BRIDGE=1
      export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1
      export WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1
      export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1   # no bwrap-under-FEX for local UI content
      export HYTALE_LAUNCHER_NO_TEST_RUN_BINARIES=1
      # Go's SIGURG-based async preemption corrupts guest state under FEX on
      # Oryon-3 (random early-init panics). Cooperative preemption only.
      export GODEBUG=asyncpreemptoff=1

      # box64 (client): Ubuntu x86 libs. OpenSSL stays emulated: native
      # wrapping breaks CRYPTO_set_mem_functions under .NET.
      # + pulseaudio/: libpulse.so.0 needs libpulsecommon-*.so from there (OpenAL -> Pulse -> PipeWire)
      export BOX64_LD_LIBRARY_PATH=${ubuntuLibs}:${ubuntuRootfs}/usr/lib/x86_64-linux-gnu/pulseaudio
      export BOX64_EMULATED_LIBS=libssl.so.3:libcrypto.so.3
      export ALSA_CONFIG_PATH=${ubuntuRootfs}/usr/share/alsa/alsa.conf   # emulated alsa-lib looks in /usr/share
      export BOX64_DYNACACHE_FOLDER=$cache/box64-${box64.version}          # cache is not portable across box64 builds
      export BOX64_NOBANNER=1

      # .NET (client): no ICU at all (the 0.6.3+ abort is inside globalization
      # init), and no W^X double-mapping of JIT pages under an emulator.
      export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
      export DOTNET_EnableWriteXorExecute=0

      exec ${fex}/bin/FEX "$launcher" "$@"
    '';
  };
  # Desktop entry. The launcher zip is just the Wails binary; its app icon is
  # embedded as a PNG resource, so pull the largest PNG out of the ELF.
  hytaleIcon = pkgs.runCommand "hytale-icon" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p $out/share/icons/hicolor/256x256/apps
    python3 - "${launcherSeed}/hytale-launcher" "$out/share/icons/hicolor/256x256/apps/hytale.png" <<'PY'
    import sys, re
    data = open(sys.argv[1], 'rb').read()
    best = b""
    for m in re.finditer(b"\x89PNG\r\n\x1a\n", data):
        end = data.find(b"IEND", m.start())
        if end == -1: continue
        png = data[m.start():end + 8]
        if len(png) > len(best): best = png
    if best: open(sys.argv[2], 'wb').write(best)
    else: print("no embedded PNG found; desktop entry will use a generic icon")
    PY
  '';
  hytaleDesktop = pkgs.makeDesktopItem {
    name = "hytale";
    desktopName = "Hytale";
    comment = "Hytale launcher and client (x86_64 under FEX)";
    exec = "${hytale}/bin/hytale";
    icon = "hytale";
    terminal = false;
    categories = [ "Game" ];
    startupNotify = false;
  };

in
{
  environment.systemPackages = [ hytale hytaleDesktop hytaleIcon ];
  # FEX/box64 client dumps are 200-900 MB; the default limits truncate them
  # before the library mappings, which makes them useless.
  # FEX cores are huge uncompressed (guest address-space reservations dump as
  # zeros) but compress to a few hundred MB; the caps are on the raw size.
  systemd.coredump.settings.Coredump = {
    ProcessSizeMax = "1T";
    ExternalSizeMax = "1T";
    MaxUse = "20G";
  };
}
