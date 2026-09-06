#!/usr/bin/env bash
set -euo pipefail

app_name="PaneGlance"
bundle_dir="dist/${app_name}.app"
contents_dir="${bundle_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
iconset_dir="${resources_dir}/AppIcon.iconset"

swift build -c release
rm -rf "$bundle_dir"
mkdir -p "$macos_dir" "$iconset_dir"
cp ".build/release/paneglance" "${macos_dir}/paneglance"

for size in 16 32 128 256 512; do
  doubled=$((size * 2))
  for suffix in "" "@2x"; do
    pixel_size=$size
    if [[ "$suffix" == "@2x" ]]; then pixel_size=$doubled; fi
    ppm_path="${iconset_dir}/icon_${size}x${size}${suffix}.ppm"
    png_path="${iconset_dir}/icon_${size}x${size}${suffix}.png"
    {
      printf 'P3\n%s %s\n255\n' "$pixel_size" "$pixel_size"
      for ((y = 0; y < pixel_size; y++)); do
        for ((x = 0; x < pixel_size; x++)); do
          if (((x - pixel_size / 2) * (x - pixel_size / 2) + (y - pixel_size / 2) * (y - pixel_size / 2) < pixel_size * pixel_size / 5)); then
            printf '48 104 220 '
          else
            printf '24 28 38 '
          fi
        done
        printf '\n'
      done
    } > "$ppm_path"
    sips -s format png "$ppm_path" --out "$png_path" >/dev/null
    rm "$ppm_path"
  done
done

iconutil -c icns "$iconset_dir" -o "${resources_dir}/AppIcon.icns"
rm -rf "$iconset_dir"
cp Resources/Info.plist "${contents_dir}/Info.plist"

codesign --force --sign - "$bundle_dir"
printf 'Bundled %s\n' "$(cd "$(dirname "$bundle_dir")" && pwd)/$(basename "$bundle_dir")"
