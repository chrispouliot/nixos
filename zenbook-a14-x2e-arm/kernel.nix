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
      # ASUS A14 DP fix #1
      #
      # Cache PMIC GLINK's boot-time HPD state in aux-hpd-bridge.
      #
      # The firmware reports HPD=connected before DRM installs the
      # HPD callback. Without this, the initial notification is lost.
      #
      # Adding DRM_BRIDGE_OP_DETECT lets DRM query the cached state
      # during normal connector detection.
      # ============================================================

      echo "Applying ASUS A14 AUX HPD state cache/detect fix"

      python3 - <<'PY'
from pathlib import Path
import re

p = Path("drivers/gpu/drm/bridge/aux-hpd-bridge.c")
s = p.read_text()


# ------------------------------------------------------------
# READ_ONCE / WRITE_ONCE
# ------------------------------------------------------------

include = "#include <linux/auxiliary_bus.h>\n"

if include not in s:
    raise SystemExit(
        "Could not find auxiliary_bus include"
    )

if "#include <linux/compiler.h>" not in s:
    s = s.replace(
        include,
        include + "#include <linux/compiler.h>\n",
        1,
    )


# ------------------------------------------------------------
# Add cached connector status to private bridge data.
# ------------------------------------------------------------

struct_re = re.compile(
    r"(struct drm_aux_hpd_bridge_data\s*\{.*?"
    r"struct device \*dev;\s*)"
    r"(\};)",
    re.S,
)

match = struct_re.search(s)

if not match:
    raise SystemExit(
        "Could not find drm_aux_hpd_bridge_data"
    )

if "enum drm_connector_status status;" not in match.group(0):
    replacement = (
        match.group(1)
        + "\tenum drm_connector_status status;\n"
        + match.group(2)
    )

    s = (
        s[:match.start()]
        + replacement
        + s[match.end():]
    )


# ------------------------------------------------------------
# Cache every PMIC-reported HPD status before forwarding the
# existing notification.
# ------------------------------------------------------------

old = """\tdrm_bridge_hpd_notify(&data->bridge, status);
"""

new = """\tWRITE_ONCE(data->status, status);

\tdev_info(data->dev,
\t\t "A14-DP: AUX cache status=%d\\n",
\t\t status);

\tdrm_bridge_hpd_notify(&data->bridge, status);
"""

if old not in s:
    raise SystemExit(
        "Could not find drm_bridge_hpd_notify call"
    )

s = s.replace(old, new, 1)


# ------------------------------------------------------------
# Add .detect() returning the last PMIC-reported state.
# ------------------------------------------------------------

attach_pos = s.find(
    "static int drm_aux_hpd_bridge_attach("
)

if attach_pos == -1:
    raise SystemExit(
        "Could not find drm_aux_hpd_bridge_attach"
    )

funcs_match = re.search(
    r"static const struct drm_bridge_funcs\s+"
    r"([A-Za-z0-9_]+)\s*=\s*\{\s*",
    s[attach_pos:],
)

if not funcs_match:
    raise SystemExit(
        "Could not find AUX HPD drm_bridge_funcs table"
    )

funcs_pos = attach_pos + funcs_match.start()

detect_function = """
static enum drm_connector_status
drm_aux_hpd_bridge_detect(struct drm_bridge *bridge,
\t\t\t  struct drm_connector *connector)
{
\tstruct drm_aux_hpd_bridge_data *data =
\t\tcontainer_of(bridge, struct drm_aux_hpd_bridge_data, bridge);
\tenum drm_connector_status status = READ_ONCE(data->status);

\tdev_info(data->dev,
\t\t "A14-DP: AUX detect returning status=%d\\n",
\t\t status);

\treturn status;
}

"""

if "drm_aux_hpd_bridge_detect(" not in s:
    s = (
        s[:funcs_pos]
        + detect_function
        + s[funcs_pos:]
    )


# ------------------------------------------------------------
# Add .detect to the bridge function table.
# ------------------------------------------------------------

funcs_match = re.search(
    r"static const struct drm_bridge_funcs\s+"
    r"([A-Za-z0-9_]+)\s*=\s*\{\s*",
    s,
)

if not funcs_match:
    raise SystemExit(
        "Could not re-find AUX HPD drm_bridge_funcs table"
    )

table_start = funcs_match.end()
table_end = s.find("};", table_start)

if table_end == -1:
    raise SystemExit(
        "Could not find end of AUX HPD drm_bridge_funcs table"
    )

table = s[table_start:table_end]

if ".detect" not in table:
    s = (
        s[:table_start]
        + "\t.detect = drm_aux_hpd_bridge_detect,\n"
        + s[table_start:]
    )


# ------------------------------------------------------------
# No HPD state is known until PMIC GLINK tells us.
# ------------------------------------------------------------

old = """\tdata->dev = &auxdev->dev;
"""

new = """\tdata->dev = &auxdev->dev;
\tWRITE_ONCE(data->status, connector_status_unknown);
"""

if old not in s:
    raise SystemExit(
        "Could not find AUX HPD data->dev initialization"
    )

s = s.replace(old, new, 1)


# ------------------------------------------------------------
# This bridge now supports both asynchronous HPD and synchronous
# connector detection.
# ------------------------------------------------------------

ops_re = re.compile(
    r"data->bridge\.ops\s*=\s*DRM_BRIDGE_OP_HPD\s*;"
)

if not ops_re.search(s):
    raise SystemExit(
        "Could not find AUX HPD bridge.ops assignment"
    )

s = ops_re.sub(
    "data->bridge.ops = DRM_BRIDGE_OP_HPD | DRM_BRIDGE_OP_DETECT;",
    s,
    count=1,
)

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
      # Build-time verification
      # ============================================================

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
      echo "Verifying ASUS A14 AUX HPD cache/detect:"
      grep -n -B3 -A8 \
        'drm_aux_hpd_bridge_detect' \
        drivers/gpu/drm/bridge/aux-hpd-bridge.c

      grep -n \
        'DRM_BRIDGE_OP_HPD.*DRM_BRIDGE_OP_DETECT' \
        drivers/gpu/drm/bridge/aux-hpd-bridge.c


      echo
      echo "Verifying ASUS A14 PMIC GLINK diagnostics:"
      grep -n -E \
        'A14-DP: (WORK|RX8180|RX8280|RX8280-DP|queue_work returned false)' \
        drivers/soc/qcom/pmic_glink_altmode.c


      echo
      echo "All ASUS A14 kernel patches applied successfully"
    '';
  });

in
linuxPackagesFor a14Kernel
