{
  lib,
  buildLinux,
  linuxPackagesFor,
  glymurSrc,
  ...
}:

let
  baseKernel = buildLinux {
    pname = "linux-glymur-a14";
    version = "7.2.0-rc5-next-20260731";
    src = glymurSrc;
    buildDTBs = true;
    ignoreConfigErrors = true;

    structuredExtraConfig = with lib.kernel; {
      ARCH_QCOM = yes;

      # This linux-next snapshot has a Rust/RCU API mismatch.
      RUST = lib.mkForce no;

      ARM_SCMI_PROTOCOL = yes;
      ARM_SCMI_TRANSPORT_MAILBOX = yes;
      ARM_SCMI_CPUFREQ = yes;

      ENERGY_MODEL = yes;
      CPU_FREQ_GOV_SCHEDUTIL = yes;
      CPU_FREQ_DEFAULT_GOV_SCHEDUTIL = yes;

      EC_ASUS_GLYMUR = module;
    };
  };

  a14Kernel = baseKernel.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # ============================================================
      # ASUS A14 USB bring-up DT fixes
      # ============================================================

      echo "Applying ASUS A14 Glymur USB bring-up DT overrides"
      cat ${./patches/a14-usb-fix.dtsi} \
        >> arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a14-ux3407na.dts

      cat ${./patches/a14-audio-left-only.dtsi} >> \
        arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a14-ux3407na.dts

      cat ${./patches/a14-edp-hbr.dtsi} \
        >> arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a14-ux3407na.dts

      # ============================================================
      # ASUS A14 external USB-C DP HBR diagnostic limit
      #
      # Direct USB-C DP intermittently times out while the QMP PHY is
      # programming HBR2 (5.4 Gbit/s). Limit only the observed external
      # controller, mdss_dp1 at af5c000, to HBR (2.7 Gbit/s). This keeps
      # the internal eDP limit independent and should make 4K60 invalid,
      # while allowing lower-bandwidth modes such as 4K30/1440p60.
      # ============================================================

      echo "Limiting ASUS A14 external DP1 to HBR for diagnostics"

      python3 - <<'PY'
from pathlib import Path

p = Path(
    "arch/arm64/boot/dts/qcom/"
    "glymur-asus-zenbook-a14-ux3407na.dts"
)
s = p.read_text()

marker = "ASUS A14 external DP1 HBR diagnostic limit"
if marker in s:
    raise SystemExit("External DP1 HBR diagnostic limit is already present")

s += """

/* ASUS A14 external DP1 HBR diagnostic limit */
&mdss_dp1_out {
	/delete-property/ link-frequencies;
	link-frequencies = /bits/ 64 <1620000000 2700000000>;
};
"""

p.write_text(s)
PY

      # ============================================================
      # ASUS A14 audio diagnostic: left-side WSA only
      #
      # Keep the stock 4-channel AudioReach frontend, but constrain
      # the WSA codec-DMA backend to 2 channels. Combined with the
      # DT override above, this keeps only:
      #
      #   swr0 / WSA
      #     - left woofer
      #     - left tweeter
      #
      # in the playback DAI link, excluding swr3 / WSA2.
      # ============================================================
      echo "Forcing ASUS A14 WSA backend to stereo"
      python3 - <<'PY'
from pathlib import Path

p = Path("sound/soc/qcom/x1e80100.c")
s = p.read_text()

# Limit the modification to x1e80100_be_hw_params_fixup().
func_start = s.find(
    "static int x1e80100_be_hw_params_fixup("
)

if func_start == -1:
    raise SystemExit(
        "Could not find x1e80100_be_hw_params_fixup()"
    )

func_end = s.find(
    "static int x1e80100_snd_hw_map_channels(",
    func_start,
)
if func_end == -1:
    raise SystemExit(
        "Could not find end of x1e80100_be_hw_params_fixup()"
    )

func = s[func_start:func_end]

# Make sure we're patching the expected function.
if "switch (cpu_dai->id)" not in func:
    raise SystemExit(
        "Could not find cpu_dai switch in x1e80100_be_hw_params_fixup()"
    )

# Avoid accidentally applying this twice.
if "channels->min = channels->max = 2;" in func:
    raise SystemExit(
        "WSA stereo backend patch appears to already be present"
    )

needle = "switch (cpu_dai->id) {"

insert = """switch (cpu_dai->id) {
\tcase WSA_CODEC_DMA_RX_0:
\tcase WSA_CODEC_DMA_RX_1:
\t\t/*
\t\t * ASUS UX3407NA diagnostic:
\t\t * only the left WSA SoundWire bus is present in the
\t\t * sound-card DAI link, so constrain this backend to stereo.
\t\t */
\t\tchannels->min = channels->max = 2;
\t\tbreak;
"""

if func.count(needle) != 1:
    raise SystemExit(
        f"Expected exactly one cpu_dai switch in hw_params fixup, "
        f"found {func.count(needle)}"
    )

patched_func = func.replace(needle, insert, 1)

s = (
    s[:func_start]
    + patched_func
    + s[func_end:]
)

p.write_text(s)
PY


      # ============================================================
      # ASUS Zenbook I2C keyboard Fn-lock support/default
      # ============================================================

      echo "Enabling ASUS Zenbook A14 HID Fn Lock support"

      python3 - <<'PY'
from pathlib import Path

p = Path("drivers/hid/hid-asus.c")
s = p.read_text()


# ------------------------------------------------------------
# Enable the existing HID Fn-lock implementation for:
#
#   ASUS 0B05:4B42
#   USB_DEVICE_ID_ASUSTEK_I2C_ZENBOOK_KEYBOARD
# ------------------------------------------------------------

old = """\t{ HID_I2C_DEVICE(USB_VENDOR_ID_ASUSTEK,
\t\tUSB_DEVICE_ID_ASUSTEK_I2C_ZENBOOK_KEYBOARD),
\t  I2C_KEYBOARD_QUIRKS | QUIRK_FILTER_CAMERA_COMPANION },
"""

new = """\t{ HID_I2C_DEVICE(USB_VENDOR_ID_ASUSTEK,
\t\tUSB_DEVICE_ID_ASUSTEK_I2C_ZENBOOK_KEYBOARD),
\t  I2C_KEYBOARD_QUIRKS | QUIRK_FILTER_CAMERA_COMPANION |
\t  QUIRK_HID_FN_LOCK },
"""

if old not in s:
    raise SystemExit(
        "Could not find ASUS Zenbook I2C keyboard device entry"
    )

s = s.replace(old, new, 1)


# ------------------------------------------------------------
# UX3407NA desired default:
#
#   media / brightness directly
#   Fn + F1-F12 for normal function keys
#
# Other ASUS devices retain the existing true default.
# ------------------------------------------------------------

old = """\tif (drvdata->quirks & QUIRK_HID_FN_LOCK) {
\t\tdrvdata->fn_lock = true;
\t\tINIT_WORK(&drvdata->fn_lock_sync_work, asus_sync_fn_lock);
\t\tasus_kbd_set_fn_lock(hdev, true);
\t}
"""

new = """\tif (drvdata->quirks & QUIRK_HID_FN_LOCK) {
\t\tdrvdata->fn_lock =
\t\t\thdev->product != USB_DEVICE_ID_ASUSTEK_I2C_ZENBOOK_KEYBOARD;
\t\tINIT_WORK(&drvdata->fn_lock_sync_work, asus_sync_fn_lock);
\t\tasus_kbd_set_fn_lock(hdev, drvdata->fn_lock);
\t}
"""

count = s.count(old)

if count != 2:
    raise SystemExit(
        f"Expected 2 ASUS Fn-lock initialization blocks, found {count}"
    )

s = s.replace(old, new)

p.write_text(s)
PY


      # ============================================================
      # ASUS A14 DP diagnostic
      #
      # Cold boot currently shows:
      #
      #   fd5000 QMP mode 0 -> 1   (DP selected)
      #   fd5000 QMP mode 1 -> 2   (overwritten by USB3-only)
      #   DRM AUX later times out
      #
      # A monitor-side DP unplug/replug causes 2 -> 1 and AUX works.
      #
      # Instrument PMIC GLINK at notification receive time and worker
      # execution time. This is logging only; it does not change mux,
      # retimer, HPD, or PHY behavior.
      # ============================================================

      echo "Adding ASUS A14 PMIC GLINK Alt Mode diagnostics"

      python3 - <<'PY'
from pathlib import Path

p = Path("drivers/soc/qcom/pmic_glink_altmode.c")
s = p.read_text()


# Log the state actually consumed by the worker.
old = """\tenum drm_connector_status conn_status;

\ttypec_switch_set(alt_port->typec_switch, alt_port->orientation);
"""

new = """\tenum drm_connector_status conn_status;

\tdev_info(altmode->dev,
\t\t "A14-DP: WORK port=%u svid=%#x mux=%u mode=%u hpd=%u irq=%u orientation=%u\\n",
\t\t alt_port->index,
\t\t alt_port->svid,
\t\t alt_port->mux_ctrl,
\t\t alt_port->mode,
\t\t alt_port->hpd_state,
\t\t alt_port->hpd_irq,
\t\t alt_port->orientation);

\ttypec_switch_set(alt_port->typec_switch, alt_port->orientation);
"""

if old not in s:
    raise SystemExit("Could not find PMIC GLINK worker preamble")

s = s.replace(old, new, 1)


# Log raw SC8180X-style notifications.
old = """\tsvid = mux == 2 ? USB_TYPEC_DP_SID : 0;

\tif (port >= ARRAY_SIZE(altmode->ports) || !altmode->ports[port].altmode) {
"""

new = """\tsvid = mux == 2 ? USB_TYPEC_DP_SID : 0;

\tdev_info(altmode->dev,
\t\t "A14-DP: RX8180 port=%u svid=%#x mux=%u mode=%u hpd=%u irq=%u orientation=%u\\n",
\t\t port, svid, mux, mode, hpd_state, hpd_irq, orientation);

\tif (port >= ARRAY_SIZE(altmode->ports) || !altmode->ports[port].altmode) {
"""

if old not in s:
    raise SystemExit("Could not find SC8180X notification decode point")

s = s.replace(old, new, 1)


# Log raw SC8280X/PAN-style notifications.
old = """\tport = notify->port_idx;
\torientation = notify->orientation;

\tif (port >= ARRAY_SIZE(altmode->ports) || !altmode->ports[port].altmode) {
"""

new = """\tport = notify->port_idx;
\torientation = notify->orientation;

\tdev_info(altmode->dev,
\t\t "A14-DP: RX8280 port=%u svid=%#x mux=%u orientation=%u\\n",
\t\t port, svid, notify->mux_ctrl, orientation);

\tif (port >= ARRAY_SIZE(altmode->ports) || !altmode->ports[port].altmode) {
"""

if old not in s:
    raise SystemExit("Could not find SC8280X notification decode point")

s = s.replace(old, new, 1)


# For DP notifications, log raw pin assignment and HPD bits too.
old = """\tif (svid == USB_TYPEC_DP_SID) {
\t\tdp = &notify->extended_data.dp;

\t\talt_port->mode = dp->pin_assignment - DPAM_HPD_A;
"""

new = """\tif (svid == USB_TYPEC_DP_SID) {
\t\tdp = &notify->extended_data.dp;

\t\tdev_info(altmode->dev,
\t\t\t "A14-DP: RX8280-DP port=%u pin=%u hpd=%u irq=%u\\n",
\t\t\t port, dp->pin_assignment, dp->hpd_state, dp->hpd_irq);

\t\talt_port->mode = dp->pin_assignment - DPAM_HPD_A;
"""

if old not in s:
    raise SystemExit("Could not find SC8280X DP payload handling")

s = s.replace(old, new, 1)


# Expose per-port work coalescing. A false return means this
# notification did not add another work item because one was already
# pending. This helps detect alt_port state being overwritten.
old = """\tqueue_work(system_freezable_wq, &alt_port->work);
"""

new = """\tif (!queue_work(system_freezable_wq, &alt_port->work))
\t\tdev_info(altmode->dev,
\t\t\t "A14-DP: queue_work returned false port=%u\\n",
\t\t\t alt_port->index);
"""

count = s.count(old)

if count != 2:
    raise SystemExit(
        f"Expected 2 PMIC GLINK port queue_work calls, found {count}"
    )

s = s.replace(old, new)

p.write_text(s)
PY


      # ============================================================
      # ASUS A14 external DP IRQ-HPD storm containment
      #
      # This kernel predates the DRM IRQ-only HPD notification API.
      # When the monitor powers down, PMIC GLINK reports short HPD IRQ
      # pulses as ordinary connected notifications. That floods DRM,
      # userspace and runtime PM with full connector hotplug handling.
      #
      # On the affected external port, acknowledge and suppress only
      # HPD-high + IRQ notifications. Real plug and unplug transitions
      # have irq=0 and continue through the normal path.
      # ============================================================

      echo "Suppressing ASUS A14 port 1 IRQ-only HPD storm"

      python3 - <<'PY'
from pathlib import Path

p = Path("drivers/soc/qcom/pmic_glink_altmode.c")
s = p.read_text()

old = """\ttypec_switch_set(alt_port->typec_switch, alt_port->orientation);

\t/*
\t * MUX_CTRL_STATE_DP4LN/USB3_DP may only be set if SVID=DP, but we need
"""

new = """\ttypec_switch_set(alt_port->typec_switch, alt_port->orientation);

\t/*
\t * ASUS A14 diagnostic workaround: this kernel cannot pass IRQ_HPD
\t * separately from a real connector hotplug. Suppress IRQ-only
\t * notifications on the observed external-DP port while preserving
\t * HPD-high plug and HPD-low unplug notifications.
\t */
\tif (alt_port->index == 1 &&
\t    alt_port->svid == USB_TYPEC_DP_SID &&
\t    alt_port->hpd_state &&
\t    alt_port->hpd_irq) {
\t\tdev_info_ratelimited(altmode->dev,
\t\t\t"A14-DP: suppressing port 1 IRQ-only HPD notification\\n");
\t\tpmic_glink_altmode_request(altmode, ALTMODE_PAN_ACK,
\t\t\t\t\t    alt_port->index);
\t\treturn;
\t}

\t/*
\t * MUX_CTRL_STATE_DP4LN/USB3_DP may only be set if SVID=DP, but we need
"""

count = s.count(old)

if count != 1:
    raise SystemExit(
        f"Expected one PMIC GLINK worker insertion point, found {count}"
    )

s = s.replace(old, new, 1)
p.write_text(s)
PY


      # ============================================================
      # ASUS A14 MSM DP HPD-state stabilization
      #
      # The HPD refactor removed the old already-connected early-out.
      # Repeated HPD-high/IRQ notifications consequently rerun full sink
      # discovery, emit userspace hotplug events, and retain additional
      # runtime-PM references.
      #
      # Also shut down the external DP PHY during force-suspend. Without
      # this, resume can begin with core_init=0 and phy_init=1, causing
      # host_phy_init() to skip the required hardware initialization.
      # ============================================================

      echo "Applying ASUS A14 MSM DP HPD-state stabilization"

      python3 - <<'PY'
from pathlib import Path

p = Path("drivers/gpu/drm/msm/dp/dp_display.c")
s = p.read_text()


def replace_once(text, old, new, description):
    count = text.count(old)

    if count != 1:
        raise SystemExit(
            f"Expected one {description}, found {count}"
        )

    return text.replace(old, new, 1)


# Do not repeat complete DPCD/EDID discovery for every HPD-high pulse.
s = replace_once(
    s,
    """\tguard(mutex)(&dp->plugged_lock);

\tret = pm_runtime_resume_and_get(&pdev->dev);""",
    """\tguard(mutex)(&dp->plugged_lock);

\t/* A14: repeated HPD-high pulses do not describe a new sink. */
\tif (dp->plugged)
\t\treturn 0;

\tret = pm_runtime_resume_and_get(&pdev->dev);""",
    "duplicate HPD plug guard",
)


# Only record a successful discovery as plugged. Clean up the PHY and
# runtime-PM reference if initial DPCD/EDID discovery fails.
s = replace_once(
    s,
    """\tdp->plugged = true;

\treturn ret;
};""",
    """\tif (!ret) {
\t\tdp->plugged = true;
\t} else {
\t\tmsm_dp_aux_enable_xfers(dp->aux, false);
\t\tmsm_dp_display_host_phy_exit(dp);
\t\tpm_runtime_put_sync(&pdev->dev);
\t}

\treturn ret;
};""",
    "HPD plugged assignment",
)


# HPD handling has already read DPCD and the EDID. Avoid immediately
# repeating those transactions from connector detect(), as well as
# acquiring another runtime-PM reference.
s = replace_once(
    s,
    """\tguard(mutex)(&priv->plugged_lock);
\tret = pm_runtime_resume_and_get(&dp->pdev->dev);""",
    """\tguard(mutex)(&priv->plugged_lock);

\t/* A14: HPD handling already validated the connected sink. */
\tif (priv->plugged)
\t\treturn connector_status_connected;

\tret = pm_runtime_resume_and_get(&dp->pdev->dev);""",
    "connected bridge-detect guard",
)


# System sleep uses pm_runtime_force_suspend(). Ensure external DP does
# not resume with its software PHY flag set while the hardware state was
# lost. The existing eDP behavior remains otherwise unchanged.
s = replace_once(
    s,
    """\tif (dp->msm_dp_display.is_edp) {
\t\tmsm_dp_display_host_phy_exit(dp);
\t\tmsm_dp_aux_hpd_disable(dp->aux);
\t}
\tmsm_dp_display_host_deinit(dp);""",
    """\t/* A14: force a real external-DP PHY init after system sleep. */
\tmsm_dp_display_host_phy_exit(dp);

\tif (dp->msm_dp_display.is_edp)
\t\tmsm_dp_aux_hpd_disable(dp->aux);

\tmsm_dp_display_host_deinit(dp);""",
    "DP runtime-suspend PHY shutdown",
)

p.write_text(s)
PY

      grep -n -E -C 5 \
        'A14: repeated HPD-high|A14: HPD handling|A14: force a real' \
        drivers/gpu/drm/msm/dp/dp_display.c

      # ============================================================
      # ASUS A14 external-DP physical-link payload validation
      #
      # wide_bus_en halves the DPU-to-DP interface clock, but it does
      # not halve the payload that must cross the physical DP link. The
      # current mode_valid() calculation consequently accepts 4K60 on
      # the temporary four-lane HBR cap even though 18 bpp still exceeds
      # its 8.64-Gbit/s payload budget.
      #
      # ============================================================

      echo "Correcting ASUS A14 DP physical-link payload validation"

      python3 - <<'PY'
from pathlib import Path

p = Path("drivers/gpu/drm/msm/dp/dp_display.c")
s = p.read_text()


def replace_once(text, old, new, description):
    count = text.count(old)

    if count != 1:
        raise SystemExit(
            f"Expected one {description}, found {count}"
        )

    return text.replace(old, new, 1)


# Wide bus is a DPU interface optimization. Only a sink mode that is
# actually 4:2:0 halves the physical DisplayPort payload requirement.
s = replace_once(
    s,
    """\tif ((drm_mode_is_420_only(&dp->connector->display_info, mode) &&
\t     msm_dp_display->panel->vsc_sdp_supported) ||
\t     msm_dp_wide_bus_available(dp))
\t\tmode_pclk_khz /= 2;""",
    """\tif (drm_mode_is_420_only(&dp->connector->display_info, mode) &&
\t    msm_dp_display->panel->vsc_sdp_supported)
\t\tmode_pclk_khz /= 2;""",
    "DP physical-link bandwidth calculation",
)

s = replace_once(
    s,
    """\tif (mode_rate_khz > supported_rate_khz)
\t\treturn MODE_BAD;""",
    """\tif (mode_rate_khz > supported_rate_khz) {
\t\tdrm_dbg_dp(dp->drm_dev,
\t\t\t   \"A14-DP: rejecting %s: payload=%u capacity=%u kbit/s bpp=%u\\n\",
\t\t\t   mode->name, mode_rate_khz, supported_rate_khz,
\t\t\t   mode_bpp);
\t\treturn MODE_BAD;
\t}""",
    "DP over-bandwidth rejection",
)


p.write_text(s)
PY

      echo
      echo "Verifying ASUS A14 DP physical-link payload validation:"
      grep -n -E -C 7 \
        'A14-DP: rejecting .*payload' \
        drivers/gpu/drm/msm/dp/dp_display.c

      # ============================================================
      # ASUS A14 DP AUX wrong-data-count handling test
      #
      # The controller reports DP_INTR_WRONG_DATA_CNT during the first
      # native AUX read. The upstream ISR currently returns without
      # completing the transfer, causing repeated 250 ms waits.
      #
      # Report a protocol error, complete the transfer, and allow DRM
      # to retry it promptly.
      # ============================================================

      echo "Handling ASUS A14 DP AUX wrong-data-count interrupts"

      python3 - <<'PY'
from pathlib import Path

p = Path("drivers/gpu/drm/msm/dp/dp_aux.c")
s = p.read_text()

def replace_once(text, old, new, description):
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"Expected one {description}, found {count}"
        )
    return text.replace(old, new, 1)

s = replace_once(
    s,
    """\tDP_AUX_ERR_NACK_DEFER,
\tDP_AUX_ERR_PHY,
};""",
    """\tDP_AUX_ERR_NACK_DEFER,
\tDP_AUX_ERR_PHY,
\tDP_AUX_ERR_DATA,
};""",
    "AUX error enum",
)

s = replace_once(
    s,
    """\t\tcase DP_AUX_ERR_TOUT:
\t\t\tret = -ETIMEDOUT;
\t\t\tbreak;""",
    """\t\tcase DP_AUX_ERR_TOUT:
\t\t\tret = -ETIMEDOUT;
\t\t\tbreak;
\t\tcase DP_AUX_ERR_DATA:
\t\t\tDRM_ERROR("A14-DP: AUX wrong data count addr=%#x request=%#x size=%zu\\n",
\t\t\t\t  msg->address, msg->request, msg->size);
\t\t\tret = -EPROTO;
\t\t\tbreak;""",
    "AUX timeout switch case",
)

s = replace_once(
    s,
    """\t} else if (isr & DP_INTR_WRONG_ADDR) {
\t\taux->aux_error_num = DP_AUX_ERR_ADDR;
\t} else if (isr & DP_INTR_TIMEOUT) {""",
    """\t} else if (isr & DP_INTR_WRONG_ADDR) {
\t\taux->aux_error_num = DP_AUX_ERR_ADDR;
\t} else if (isr & DP_INTR_WRONG_DATA_CNT) {
\t\taux->aux_error_num = DP_AUX_ERR_DATA;
\t} else if (isr & DP_INTR_TIMEOUT) {""",
    "AUX wrong-address ISR branch",
)

p.write_text(s)
PY

      grep -n -B3 -A7 \
        'A14-DP: AUX wrong data count' \
        drivers/gpu/drm/msm/dp/dp_aux.c

      # ============================================================
      # ASUS A14 external-DP PHY/link-clock error propagation
      #
      # The QMP combo-PHY driver currently discards the return value
      # from configure_dp_phy(). A PLL-lock failure is consequently
      # reported to the generic PHY core as a successful power-on.
      # The MSM DP driver also ignores phy_configure()/phy_power_on()
      # failures and leaves the PHY powered if the downstream link
      # clock cannot start. A later unplug can then call phy_exit()
      # while the PHY is still powered, which can freeze or reset the
      # machine.
      #
      # This linux-next snapshot also carries the first revision of the
      # Glymur DP PHY programming patch. That revision always programs
      # DP_PHY_MODE=0x5c, even for a reversed Type-C orientation, and
      # overwrites the HPG-required AUX_CFG2=0x06 with 0xa4 immediately
      # before PLL startup. Apply the reviewed follow-up corrections.
      #
      # Propagate the real QMP result, assert PHY power-down on failure,
      # check every mainlink startup stage, and unwind a powered PHY if
      # a later stage fails. Do not retry here: the full PHY reinit test
      # timed out identically and added unsafe state churn.
      #
      # The crash-contained test now reaches the v8 C_READY poll with
      # status=0 and safely returns -ETIMEDOUT. Snapshot the shared-combo,
      # PLL and DP-PHY state around that first startup, and temporarily
      # extend only the C_READY diagnostic wait from 10 ms to 50 ms.
      # ============================================================

      echo "Applying reviewed Glymur DP PHY corrections and error propagation"

      python3 - <<'PY'
from pathlib import Path


def replace_once(text, old, new, description):
    count = text.count(old)

    if count != 1:
        raise SystemExit(
            f"Expected one {description}, found {count}"
        )

    return text.replace(old, new, 1)


# ------------------------------------------------------------
# QMP combo PHY: do not turn a PLL/configuration timeout into a
# successful generic-PHY power-on. Also leave the hardware in its
# explicit DP power-down state so a retry starts from a known state.
# ------------------------------------------------------------

p = Path("drivers/phy/qualcomm/phy-qcom-qmp-combo.c")
s = p.read_text()


# The first Glymur revision introduced a v8-only helper that always writes
# DP_PHY_MODE=0x5c. The common helper already writes 0x4c for a reversed
# Type-C orientation and 0x5c for a normal orientation, as required by the
# reviewed follow-up. Remove the now-unused v8-only helper after redirecting
# the one caller below.
mode_start = s.find(
    "static bool qmp_v8_combo_configure_dp_mode(struct qmp_combo *qmp)"
)
mode_end = s.find(
    "\nstatic void qmp_v3_configure_dp_tx(struct qmp_combo *qmp)",
    mode_start,
)

if mode_start == -1 or mode_end == -1:
    raise SystemExit("Could not isolate qmp_v8_combo_configure_dp_mode()")

s = s[:mode_start] + s[mode_end:]


# Identify the precise v8 QMP wait that times out. The generic -110 log
# cannot distinguish clock programming, C_READY, PLL/common readiness,
# or final DP PHY readiness.
helper_start = s.find(
    "static int qmp_v8_helper_configure_dp_phy(struct qmp_combo *qmp)"
)
helper_end = s.find(
    "\nstatic void qmp_v8_dp_aux_init(struct qmp_combo *qmp)",
    helper_start,
)

if helper_start == -1 or helper_end == -1:
    raise SystemExit("Could not isolate qmp_v8_helper_configure_dp_phy()")

helper = s[helper_start:helper_end]

helper = replace_once(
    helper,
    "\tqmp_v8_combo_configure_dp_mode(qmp);",
    "\tqmp_combo_configure_dp_mode(qmp);",
    "Glymur orientation-aware DP mode setup",
)

helper = replace_once(
    helper,
    "\twritel(0xa4, qmp->dp_dp_phy + QSERDES_DP_PHY_AUX_CFG2);",
    "\twritel(0x06, qmp->dp_dp_phy + QSERDES_DP_PHY_AUX_CFG2);",
    "Glymur HPG AUX_CFG2 value",
)

helper = replace_once(
    helper,
    """\tret = qmp->cfg->configure_dp_clocks(qmp);
\tif (ret)
\t\treturn ret;""",
    """\tret = qmp->cfg->configure_dp_clocks(qmp);
\tif (ret) {
\t\tdev_err(qmp->dev,
\t\t\t\"A14-DP: QMP v8 clock configuration failed ret=%d rate=%u lanes=%u orientation=%u\\n\",
\t\t\tret, qmp->dp_opts.link_rate, qmp->dp_opts.lanes,
\t\t\tqmp->orientation);
\t\treturn ret;
\t}""",
    "QMP v8 clock failure return",
)

helper = replace_once(
    helper,
    """\twritel(0x20, qmp->dp_serdes + cfg->regs[QPHY_COM_RESETSM_CNTRL]);""",
    """\tdev_info(qmp->dev,
\t\t\t"A14-DP: QMP pre-start common reset=%#x c_ready=%#x cmn=%#x bias=%#x clk_fwd=%#x ip_dp=%#x\\n",
\t\t\treadl(qmp->dp_serdes + cfg->regs[QPHY_COM_RESETSM_CNTRL]),
\t\t\treadl(qmp->dp_serdes + cfg->regs[QPHY_COM_C_READY_STATUS]),
\t\t\treadl(qmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS]),
\t\t\treadl(qmp->dp_serdes + cfg->regs[QPHY_COM_BIAS_EN_CLKBUFLR_EN]),
\t\t\treadl(qmp->dp_serdes + QSERDES_V8_USB43_COM_CLK_FWD_CONFIG_1),
\t\t\treadl(qmp->dp_serdes + QSERDES_V8_USB43_COM_IP_CTRL_AND_DP_SEL));
\tdev_info(qmp->dev,
\t\t\t"A14-DP: QMP pre-start rate hsclk=%#x dec=%#x lock1=%#x lock2=%#x\\n",
\t\t\treadl(qmp->dp_serdes + QSERDES_V8_USB43_COM_HSCLK_SEL_1),
\t\t\treadl(qmp->dp_serdes + QSERDES_V8_USB43_COM_DEC_START_MODE0),
\t\t\treadl(qmp->dp_serdes + QSERDES_V8_USB43_COM_LOCK_CMP1_MODE0),
\t\t\treadl(qmp->dp_serdes + QSERDES_V8_USB43_COM_LOCK_CMP2_MODE0));
\tdev_info(qmp->dev,
\t\t\t"A14-DP: QMP pre-start phy pd=%#x mode=%#x cfg=%#x cfg1=%#x aux2=%#x status=%#x\\n",
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_PD_CTL),
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_MODE),
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_CFG),
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_CFG_1),
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_AUX_CFG2),
\t\t\treadl(qmp->dp_dp_phy + cfg->regs[QPHY_DP_PHY_STATUS]));

\twritel(0x20, qmp->dp_serdes + cfg->regs[QPHY_COM_RESETSM_CNTRL]);""",
    "QMP v8 pre-start register snapshot",
)

helper = replace_once(
    helper,
    """\tif (readl_poll_timeout(qmp->dp_serdes + cfg->regs[QPHY_COM_C_READY_STATUS],
\t\t\tstatus,
\t\t\t((status & BIT(0)) > 0),
\t\t\t500,
\t\t\t10000))
\t\treturn -ETIMEDOUT;""",
    """\tret = readl_poll_timeout(
\t\tqmp->dp_serdes + cfg->regs[QPHY_COM_C_READY_STATUS],
\t\tstatus, status & BIT(0), 500, 50000);
\tdev_info(qmp->dev,
\t\t\t"A14-DP: QMP C_READY result ret=%d status=%#x reset=%#x cmn=%#x timeout_us=50000\\n",
\t\t\tret, status,
\t\t\treadl(qmp->dp_serdes + cfg->regs[QPHY_COM_RESETSM_CNTRL]),
\t\t\treadl(qmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS]));
\tdev_info(qmp->dev,
\t\t\t"A14-DP: QMP C_READY phy pd=%#x mode=%#x cfg=%#x cfg1=%#x aux2=%#x status=%#x\\n",
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_PD_CTL),
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_MODE),
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_CFG),
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_CFG_1),
\t\t\treadl(qmp->dp_dp_phy + QSERDES_DP_PHY_AUX_CFG2),
\t\t\treadl(qmp->dp_dp_phy + cfg->regs[QPHY_DP_PHY_STATUS]));
\tif (ret) {
\t\tdev_err(qmp->dev,
\t\t\t\"A14-DP: QMP v8 helper C_READY timeout status=%#x rate=%u lanes=%u orientation=%u\\n\",
\t\t\tstatus, qmp->dp_opts.link_rate, qmp->dp_opts.lanes,
\t\t\tqmp->orientation);
\t\treturn ret;
\t}""",
    "QMP v8 helper C_READY poll",
)

helper = replace_once(
    helper,
    """\tif (readl_poll_timeout(qmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS],
\t\t\tstatus,
\t\t\t((status & BIT(0)) > 0),
\t\t\t500,
\t\t\t10000))
\t\treturn -ETIMEDOUT;""",
    """\tret = readl_poll_timeout(
\t\tqmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS],
\t\tstatus, status & BIT(0), 500, 10000);
\tif (ret) {
\t\tdev_err(qmp->dev,
\t\t\t\"A14-DP: QMP v8 helper CMN bit0 timeout status=%#x rate=%u lanes=%u orientation=%u\\n\",
\t\t\tstatus, qmp->dp_opts.link_rate, qmp->dp_opts.lanes,
\t\t\tqmp->orientation);
\t\treturn ret;
\t}""",
    "QMP v8 helper CMN bit0 poll",
)

helper = replace_once(
    helper,
    """\tif (readl_poll_timeout(qmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS],
\t\t\tstatus,
\t\t\t((status & BIT(1)) > 0),
\t\t\t500,
\t\t\t10000))
\t\treturn -ETIMEDOUT;""",
    """\tret = readl_poll_timeout(
\t\tqmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS],
\t\tstatus, status & BIT(1), 500, 10000);
\tif (ret) {
\t\tdev_err(qmp->dev,
\t\t\t\"A14-DP: QMP v8 helper CMN bit1 timeout status=%#x rate=%u lanes=%u orientation=%u\\n\",
\t\t\tstatus, qmp->dp_opts.link_rate, qmp->dp_opts.lanes,
\t\t\tqmp->orientation);
\t\treturn ret;
\t}""",
    "QMP v8 helper CMN bit1 poll",
)

s = s[:helper_start] + helper + s[helper_end:]


final_start = s.find(
    "static int qmp_v8_configure_dp_phy(struct qmp_combo *qmp)",
    helper_end,
)
final_end = s.find(
    "\n/*\n * We need to calibrate the aux setting here",
    final_start,
)

if final_start == -1 or final_end == -1:
    raise SystemExit("Could not isolate qmp_v8_configure_dp_phy()")

final = s[final_start:final_end]

final = replace_once(
    final,
    """\tret = qmp_v8_helper_configure_dp_phy(qmp);
\tif (ret < 0)
\t\treturn ret;""",
    """\tret = qmp_v8_helper_configure_dp_phy(qmp);
\tif (ret < 0) {
\t\tdev_err(qmp->dev,
\t\t\t\"A14-DP: QMP v8 helper failed ret=%d rate=%u lanes=%u orientation=%u\\n\",
\t\t\tret, dp_opts->link_rate, dp_opts->lanes,
\t\t\tqmp->orientation);
\t\treturn ret;
\t}""",
    "QMP v8 helper failure propagation",
)

final = replace_once(
    final,
    """\tif (readl_poll_timeout(qmp->dp_dp_phy + cfg->regs[QPHY_DP_PHY_STATUS],
\t\t\tstatus,
\t\t\t((status & BIT(0)) > 0),
\t\t\t500,
\t\t\t10000))
\t\treturn -ETIMEDOUT;""",
    """\tret = readl_poll_timeout(
\t\tqmp->dp_dp_phy + cfg->regs[QPHY_DP_PHY_STATUS],
\t\tstatus, status & BIT(0), 500, 10000);
\tif (ret) {
\t\tdev_err(qmp->dev,
\t\t\t\"A14-DP: QMP v8 DP PHY ready timeout status=%#x rate=%u lanes=%u orientation=%u\\n\",
\t\t\tstatus, dp_opts->link_rate, dp_opts->lanes,
\t\t\tqmp->orientation);
\t\treturn ret;
\t}""",
    "QMP v8 final DP PHY status poll",
)

final = replace_once(
    final,
    """\tif (readl_poll_timeout(qmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS],
\t\t\tstatus,
\t\t\t((status & BIT(0)) > 0),
\t\t\t500,
\t\t\t10000))
\t\treturn -ETIMEDOUT;""",
    """\tret = readl_poll_timeout(
\t\tqmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS],
\t\tstatus, status & BIT(0), 500, 10000);
\tif (ret) {
\t\tdev_err(qmp->dev,
\t\t\t\"A14-DP: QMP v8 final CMN bit0 timeout status=%#x rate=%u lanes=%u orientation=%u\\n\",
\t\t\tstatus, dp_opts->link_rate, dp_opts->lanes,
\t\t\tqmp->orientation);
\t\treturn ret;
\t}""",
    "QMP v8 final CMN bit0 poll",
)

final = replace_once(
    final,
    """\tif (readl_poll_timeout(qmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS],
\t\t\tstatus,
\t\t\t((status & BIT(1)) > 0),
\t\t\t500,
\t\t\t10000))
\t\treturn -ETIMEDOUT;""",
    """\tret = readl_poll_timeout(
\t\tqmp->dp_serdes + cfg->regs[QPHY_COM_CMN_STATUS],
\t\tstatus, status & BIT(1), 500, 10000);
\tif (ret) {
\t\tdev_err(qmp->dev,
\t\t\t\"A14-DP: QMP v8 final CMN bit1 timeout status=%#x rate=%u lanes=%u orientation=%u\\n\",
\t\t\tstatus, dp_opts->link_rate, dp_opts->lanes,
\t\t\tqmp->orientation);
\t\treturn ret;
\t}""",
    "QMP v8 final CMN bit1 poll",
)

s = s[:final_start] + final + s[final_end:]

s = replace_once(
    s,
    """static int qmp_combo_dp_power_on(struct phy *phy)
{
	struct qmp_combo *qmp = phy_get_drvdata(phy);
	const struct qmp_phy_cfg *cfg = qmp->cfg;
	void __iomem *tx = qmp->dp_tx;
	void __iomem *tx2 = qmp->dp_tx2;

	mutex_lock(&qmp->phy_mutex);

	qmp_combo_dp_serdes_init(qmp);

	qmp_configure_lane(qmp->dev, tx, cfg->dp_tx_tbl, cfg->dp_tx_tbl_num, 1);
	qmp_configure_lane(qmp->dev, tx2, cfg->dp_tx_tbl, cfg->dp_tx_tbl_num, 2);

	/* Configure special DP tx tunings */
	cfg->configure_dp_tx(qmp);

	/* Configure link rate, swing, etc. */
	cfg->configure_dp_phy(qmp);

	qmp->dp_powered_on = true;

	mutex_unlock(&qmp->phy_mutex);

	return 0;
}
""",
    """static int qmp_combo_dp_power_on(struct phy *phy)
{
	struct qmp_combo *qmp = phy_get_drvdata(phy);
	const struct qmp_phy_cfg *cfg = qmp->cfg;
	void __iomem *tx = qmp->dp_tx;
	void __iomem *tx2 = qmp->dp_tx2;
	int ret;

	mutex_lock(&qmp->phy_mutex);

	dev_info(qmp->dev,
		"A14-DP: QMP power-on enter init=%d usb_init=%u dp_init=%u powered=%u qmp_mode=%u phy_mode=%u orientation=%u com_reset=%#x typec=%#x mode_ctrl=%#x\\n",
		qmp->init_count, qmp->usb_init_count, qmp->dp_init_count,
		qmp->dp_powered_on, qmp->qmpphy_mode, qmp->phy_mode,
		qmp->orientation,
		readl(qmp->com + QPHY_V3_DP_COM_RESET_OVRD_CTRL),
		readl(qmp->com + QPHY_V3_DP_COM_TYPEC_CTRL),
		readl(qmp->com + QPHY_V3_DP_COM_PHY_MODE_CTRL));

	qmp_combo_dp_serdes_init(qmp);

	qmp_configure_lane(qmp->dev, tx, cfg->dp_tx_tbl, cfg->dp_tx_tbl_num, 1);
	qmp_configure_lane(qmp->dev, tx2, cfg->dp_tx_tbl, cfg->dp_tx_tbl_num, 2);

	/* Configure special DP tx tunings */
	cfg->configure_dp_tx(qmp);

	/* Configure link rate, swing, etc. */
	ret = cfg->configure_dp_phy(qmp);
	if (ret) {
		dev_err(qmp->dev,
			"A14-DP: DP PHY configuration failed: %d\\n", ret);
		writel(DP_PHY_PD_CTL_PSR_PWRDN,
		       qmp->dp_dp_phy + QSERDES_DP_PHY_PD_CTL);
		qmp->dp_powered_on = false;
	} else {
		qmp->dp_powered_on = true;
	}

	mutex_unlock(&qmp->phy_mutex);

	return ret;
}
""",
    "QMP DP power-on function",
)

p.write_text(s)


# ------------------------------------------------------------
# MSM DP: honor PHY and OPP errors and balance phy_power_on() if
# link-clock enable fails. This specifically prevents a later HPD
# unplug from exiting a PHY that the generic PHY core still regards
# as powered.
# ------------------------------------------------------------

p = Path("drivers/gpu/drm/msm/dp/dp_ctrl.c")
s = p.read_text()

s = replace_once(
    s,
    """static int msm_dp_ctrl_enable_mainlink_clocks(struct msm_dp_ctrl_private *ctrl)
{
	int ret = 0;
	struct phy *phy = ctrl->phy;
	const u8 *dpcd = ctrl->panel->dpcd;

	ctrl->phy_opts.dp.lanes = ctrl->link->link_params.num_lanes;
	ctrl->phy_opts.dp.link_rate = ctrl->link->link_params.rate / 100;
	ctrl->phy_opts.dp.ssc = drm_dp_max_downspread(dpcd);

	phy_configure(phy, &ctrl->phy_opts);
	phy_power_on(phy);

	dev_pm_opp_set_rate(ctrl->dev, ctrl->link->link_params.rate * 1000);
	ret = msm_dp_ctrl_link_clk_enable(&ctrl->msm_dp_ctrl);
	if (ret)
		DRM_ERROR("Unable to start link clocks. ret=%d\\n", ret);

	drm_dbg_dp(ctrl->drm_dev, "link rate=%d\\n", ctrl->link->link_params.rate);

	return ret;
}
""",
    """static int msm_dp_ctrl_enable_mainlink_clocks(struct msm_dp_ctrl_private *ctrl)
{
	struct phy *phy = ctrl->phy;
	const u8 *dpcd = ctrl->panel->dpcd;
	int ret;

	ctrl->phy_opts.dp.lanes = ctrl->link->link_params.num_lanes;
	ctrl->phy_opts.dp.link_rate = ctrl->link->link_params.rate / 100;
	ctrl->phy_opts.dp.ssc = drm_dp_max_downspread(dpcd);

	ret = phy_configure(phy, &ctrl->phy_opts);
	if (ret) {
		DRM_ERROR("A14-DP: failed to configure DP PHY. ret=%d\\n", ret);
		return ret;
	}

	ret = phy_power_on(phy);
	if (ret) {
		DRM_ERROR("A14-DP: failed to power on DP PHY. ret=%d\\n", ret);
		return ret;
	}

	ret = dev_pm_opp_set_rate(ctrl->dev,
				  ctrl->link->link_params.rate * 1000);
	if (ret) {
		DRM_ERROR("A14-DP: failed to set DP OPP rate. ret=%d\\n", ret);
		goto power_off_phy;
	}

	ret = msm_dp_ctrl_link_clk_enable(&ctrl->msm_dp_ctrl);
	if (ret) {
		DRM_ERROR("Unable to start link clocks. ret=%d\\n", ret);
		goto power_off_phy;
	}

	drm_dbg_dp(ctrl->drm_dev, "link rate=%d\\n", ctrl->link->link_params.rate);

	return 0;

power_off_phy:
	/* Balance the successful phy_power_on() before returning failure. */
	phy_power_off(phy);
	return ret;
}
""",
    "MSM DP mainlink clock startup function",
)


p.write_text(s)
PY

      echo
      echo "Verifying reviewed Glymur DP PHY corrections:"
      sed -n \
        '/static int qmp_v8_helper_configure_dp_phy/,/static void qmp_v8_dp_aux_init/p' \
        drivers/phy/qualcomm/phy-qcom-qmp-combo.c | \
        grep -E \
          'qmp_combo_configure_dp_mode\(qmp\)|writel\(0x06, .*QSERDES_DP_PHY_AUX_CFG2'
      ! grep -q 'qmp_v8_combo_configure_dp_mode' \
        drivers/phy/qualcomm/phy-qcom-qmp-combo.c

      echo
      echo "Verifying ASUS A14 external-DP PHY/link-clock error propagation:"
      grep -n -E -C 3 \
        'A14-DP: QMP (power-on|pre-start|C_READY)|A14-DP: QMP v8 (helper|DP PHY|final|clock)' \
        drivers/phy/qualcomm/phy-qcom-qmp-combo.c
      grep -n -F \
        'status & BIT(0), 500, 50000' \
        drivers/phy/qualcomm/phy-qcom-qmp-combo.c
      grep -n -B5 -A16 \
        'A14-DP: DP PHY configuration failed' \
        drivers/phy/qualcomm/phy-qcom-qmp-combo.c
      grep -n -B8 -A30 \
        'A14-DP: failed to power on DP PHY' \
        drivers/gpu/drm/msm/dp/dp_ctrl.c

      # ============================================================
      # ASUS A14 USB-C suspend workaround
      #
      # pm_test=devices succeeds, while pm_test=platform power-cycles
      # the USB-C controller and combo-PHY GDSCs during suspend_noirq.
      # On resume, USB0 (SID 0x1420) faults through the SMMU, while the
      # second controller's xHCI can also die. The associated DP0 PHY
      # stops supplying its link clock, wedging the DRM resume commit.
      #
      # Keep both USB-C controller and combo-PHY domains on. Clocks and
      # devices may still idle, but these four GDSCs will not collapse
      # during system suspend.
      # ============================================================

      echo "Keeping ASUS A14 USB-C power domains on across suspend"

      python3 - <<'PY'
from pathlib import Path

p = Path("drivers/clk/qcom/gcc-glymur.c")
s = p.read_text()

for name in (
    "gcc_usb30_prim_gdsc",
    "gcc_usb_0_phy_gdsc",
    "gcc_usb30_sec_gdsc",
    "gcc_usb_1_phy_gdsc",
):
    marker = f"static struct gdsc {name} = {{"
    start = s.find(marker)

    if start == -1:
        raise SystemExit(f"Could not find {name}")

    end = s.find("\n};", start)

    if end == -1:
        raise SystemExit(f"Could not find end of {name}")

    end += len("\n};")
    block = s[start:end]

    old = ".flags = POLL_CFG_GDSCR | RETAIN_FF_ENABLE,"
    new = ".flags = POLL_CFG_GDSCR | RETAIN_FF_ENABLE | ALWAYS_ON,"

    if new in block:
        continue

    if block.count(old) != 1:
        raise SystemExit(f"Unexpected flags in {name}")

    block = block.replace(old, new, 1)
    s = s[:start] + block + s[end:]

p.write_text(s)
PY


      # ============================================================
      # Build-time verification
      # ============================================================

      echo
      echo "Verifying ASUS A14 external DP1 HBR limit:"
      sed -n '/ASUS A14 external DP1 HBR diagnostic limit/,/};/p' \
        arch/arm64/boot/dts/qcom/glymur-asus-zenbook-a14-ux3407na.dts | \
        grep -F 'link-frequencies = /bits/ 64 <1620000000 2700000000>'


      echo
      echo "Verifying ASUS A14 left-only WSA backend:"
      grep -n -B4 -A12 \
        'channels->min = channels->max = 2' \
        sound/soc/qcom/x1e80100.c


      echo
      echo "Verifying ASUS A14 Fn-lock patch:"
      grep -n -B2 -A6 \
        'hdev->product != USB_DEVICE_ID_ASUSTEK_I2C_ZENBOOK_KEYBOARD' \
        drivers/hid/hid-asus.c


      echo
      echo "Verifying ASUS A14 PMIC GLINK diagnostics:"
      grep -n -E \
        'A14-DP: (WORK|RX8180|RX8280|RX8280-DP|queue_work returned false)' \
        drivers/soc/qcom/pmic_glink_altmode.c


      echo
      echo "Verifying ASUS A14 IRQ-only HPD containment:"
      grep -n -B7 -A5 \
        'A14-DP: suppressing port 1 IRQ-only HPD notification' \
        drivers/soc/qcom/pmic_glink_altmode.c


      echo
      echo "Verifying ASUS A14 USB-C suspend workaround:"
      for gdsc in \
        gcc_usb30_prim_gdsc \
        gcc_usb_0_phy_gdsc \
        gcc_usb30_sec_gdsc \
        gcc_usb_1_phy_gdsc
      do
        sed -n "/static struct gdsc $gdsc = {/,/};/p" \
          drivers/clk/qcom/gcc-glymur.c | \
          grep -F 'POLL_CFG_GDSCR | RETAIN_FF_ENABLE | ALWAYS_ON'
      done


      echo
      echo "All ASUS A14 kernel patches applied successfully"
    '';
  });

in
linuxPackagesFor a14Kernel
