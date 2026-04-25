The Asus G14 2025 has a bug in the BIOS ACPI where a wakeup event is sent to the dedicated GPU (nvidia, in my case) every time the battery decreases
one tick (eg 80% -> 79%). This bug can be fixed by editing and recompiling the Asus ACPI file.

This description and find is from the Asus Linux discord group.

Get the ACPI DSDT file
`sudo cat /sys/firmware/acpi/tables/DSDT > dsdt.dat && iasl dsdt.dat`

edit the `dsdt.dl` file. Find the following method

`Method (STPL, 0, NotSerialized)`

Remove the sleep wakeup call
```
  }
  
  Sleep (0x64)
  Notify (NPCF, 0xC2) // Hardware-Specific
-  Sleep (0x64)
-  Notify (NPCF, 0xC0)
}
```

Bump the version
```
-DefinitionBlock ("", "DSDT", 2, "_ASUS_", "Notebook", 0x01072009)
+DefinitionBlock ("", "DSDT", 2, "_ASUS_", "Notebook", 0x0107200A)
```

Optional, if the compile does not work fix Asus BIOS compiliation error by fixing this line
```
-    External (_SB_.ATKD.WMNB.M009, MethodObj)    // 1 Arguments
+    External (M009, MethodObj)    // 1 Arguments
```

Compile to an AML file

`iasl -tc dsdt.dsl`

Now patch the DSDT on your system with the new one. This varies by system. On NixOS, it is very simple.
Create the following path from wherever you are

`kernel/firmware/acpi/dsdt.aml`

Generate an acpio file with the path retained

`find kernel | cpio -H newc --create > acpi-override.cpio`

Move the file to your /etc/nixos directory

Add the local file to your configuration
```
# Fix the Asus BIOS ACPI that would trigger dGPU wakeup on battery tick decrease
boot.initrd.prepend = [ "${./acpi-override.cpio}" ];
```
