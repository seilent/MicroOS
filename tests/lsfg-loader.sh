#!/usr/bin/env bash
set -euo pipefail

rpms=${1:?usage: lsfg-loader.sh <lsfg-vk rpm dir>}
fail() { echo "lsfg-loader: $*" >&2; exit 1; }
arch=$(uname -m)
icd=/usr/share/vulkan/icd.d/lvp_icd.$arch.json
layer=VK_LAYER_LSFGVK_frame_generation
[[ -f $icd ]] || fail "no lavapipe ICD $icd"
rpm -q lsfg-vk >/dev/null || fail "lsfg-vk is not installed"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
found=("$rpms"/lsfg-vk-tests-*.noarch.rpm)
[[ ${#found[@]} == 1 && -f ${found[0]} ]] || fail "expected one lsfg-vk-tests RPM in $rpms"
rpm2archive -n - <"${found[0]}" | tar -x -C "$tmp" --no-same-owner
dlls=$tmp/usr/share/lsfg-vk/tests

cat >"$tmp/probe.py" <<'PY'
import ctypes


class ApplicationInfo(ctypes.Structure):
    _fields_ = [("sType", ctypes.c_int), ("pNext", ctypes.c_void_p), ("pApplicationName", ctypes.c_char_p),
                ("applicationVersion", ctypes.c_uint32), ("pEngineName", ctypes.c_char_p),
                ("engineVersion", ctypes.c_uint32), ("apiVersion", ctypes.c_uint32)]


class InstanceCreateInfo(ctypes.Structure):
    _fields_ = [("sType", ctypes.c_int), ("pNext", ctypes.c_void_p), ("flags", ctypes.c_uint32),
                ("pApplicationInfo", ctypes.POINTER(ApplicationInfo)), ("enabledLayerCount", ctypes.c_uint32),
                ("ppEnabledLayerNames", ctypes.c_void_p), ("enabledExtensionCount", ctypes.c_uint32),
                ("ppEnabledExtensionNames", ctypes.c_void_p)]


vulkan = ctypes.CDLL("libvulkan.so.1")
vulkan.vkCreateInstance.restype = ctypes.c_int
vulkan.vkCreateInstance.argtypes = [ctypes.POINTER(InstanceCreateInfo), ctypes.c_void_p,
                                    ctypes.POINTER(ctypes.c_void_p)]
vulkan.vkDestroyInstance.restype = None
vulkan.vkDestroyInstance.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
app = ApplicationInfo(0, None, b"lsfg-loader", 1, None, 0, (1 << 22) | (3 << 12))
info = InstanceCreateInfo(1, None, 0, ctypes.pointer(app), 0, None, 0, None)
instance = ctypes.c_void_p()
result = vulkan.vkCreateInstance(ctypes.byref(info), None, ctypes.byref(instance))
with open("/proc/self/maps", encoding="utf-8") as maps:
    mapped = any(line.rstrip().endswith("/liblsfg-vk-layer.so") for line in maps)
print(f"vkCreateInstance {result} {'mapped' if mapped else 'not-mapped'}", flush=True)
if result == 0:
    vulkan.vkDestroyInstance(instance, None)
PY

probe() {
  local name=$1
  shift
  env -i PATH=/usr/bin HOME="$tmp/home" VK_DRIVER_FILES="$icd" VK_LOADER_DEBUG=layer "$@" \
    python3 "$tmp/probe.py" >"$tmp/$name" 2>&1 || fail "$name: probe exited $?: $(<"$tmp/$name")"
  echo "== $name"
  grep -E "LSFGVK|lsfg-vk|vkCreateInstance" "$tmp/$name" || true
}

inserted="Insert instance layer \"$layer\""
broken="lsfg-vk: something went wrong during lsfg-vk layer initialization"

probe on LSFGVK_ENV=1 LSFGVK_DLL_PATH="$dlls/good.dll"
grep -qx 'vkCreateInstance 0 mapped' "$tmp/on" || fail "on: vkCreateInstance failed or the layer is not loaded"
grep -qF "$inserted" "$tmp/on" || fail "on: the loader did not insert $layer"
! grep -qF "$broken" "$tmp/on" || fail "on: the layer refused the synthetic good DLL"

probe off LSFGVK_DLL_PATH="$dlls/good.dll"
grep -qx 'vkCreateInstance 0 not-mapped' "$tmp/off" || fail "off: vkCreateInstance failed or the layer is loaded without LSFGVK_ENV"
! grep -qF "$inserted" "$tmp/off" || fail "off: the loader inserted $layer without LSFGVK_ENV"

probe disabled LSFGVK_ENV=1 DISABLE_LSFGVK=1 LSFGVK_DLL_PATH="$dlls/good.dll"
grep -qx 'vkCreateInstance 0 not-mapped' "$tmp/disabled" || fail "disabled: vkCreateInstance failed or the layer is loaded with DISABLE_LSFGVK"
! grep -qF "$inserted" "$tmp/disabled" || fail "disabled: the loader inserted $layer with DISABLE_LSFGVK"

probe not-spirv LSFGVK_ENV=1 LSFGVK_DLL_PATH="$dlls/not-spirv.dll"
grep -qE '^vkCreateInstance 0 ' "$tmp/not-spirv" || fail "not-spirv: vkCreateInstance failed"
grep -qxF -e "- unable to use $dlls/not-spirv.dll" "$tmp/not-spirv" || fail "not-spirv: the layer did not refuse not-spirv.dll"
! grep -qF "$inserted" "$tmp/not-spirv" || fail "not-spirv: the loader inserted $layer"

echo "lsfg-loader: ok ($(rpm -q lsfg-vk))"
