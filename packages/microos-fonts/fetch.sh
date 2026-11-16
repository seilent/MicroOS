#!/usr/bin/env bash
set -euo pipefail

work=${1:?usage: fetch.sh <workdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"

fetch() {
  curl -fsSL --retry 3 -o "$work/$3" "$1"
  echo "$2  $work/$3" | sha256sum -c -
}

gf=https://raw.githubusercontent.com/google/fonts/$GF_REF
mdi=https://raw.githubusercontent.com/google/material-design-icons/$MDI_REF

fetch "$gf/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf" "$SPACEGROTESK_SHA256" "SpaceGrotesk.ttf"
fetch "$gf/ofl/spacegrotesk/OFL.txt" "$SPACEGROTESK_OFL_SHA256" "SpaceGrotesk-OFL.txt"
fetch "$gf/ofl/readexpro/ReadexPro%5BHEXP%2Cwght%5D.ttf" "$READEXPRO_SHA256" "ReadexPro.ttf"
fetch "$gf/ofl/readexpro/OFL.txt" "$READEXPRO_OFL_SHA256" "ReadexPro-OFL.txt"
fetch "$gf/ofl/rubik/Rubik%5Bwght%5D.ttf" "$RUBIK_SHA256" "Rubik.ttf"
fetch "$gf/ofl/rubik/Rubik-Italic%5Bwght%5D.ttf" "$RUBIK_ITALIC_SHA256" "Rubik-Italic.ttf"
fetch "$gf/ofl/rubik/OFL.txt" "$RUBIK_OFL_SHA256" "Rubik-OFL.txt"
fetch "$gf/ofl/googlesansflex/GoogleSansFlex%5BROND%2Copsz%2Cslnt%2Cwdth%2Cwght%5D.ttf" "$GOOGLESANSFLEX_SHA256" "GoogleSansFlex.ttf"
fetch "$gf/ofl/googlesansflex/OFL.txt" "$GOOGLESANSFLEX_OFL_SHA256" "GoogleSansFlex-OFL.txt"
fetch "$mdi/variablefont/MaterialSymbolsOutlined%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf" "$MATERIALSYMBOLS_OUTLINED_SHA256" "MaterialSymbolsOutlined.ttf"
fetch "$mdi/variablefont/MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf" "$MATERIALSYMBOLS_ROUNDED_SHA256" "MaterialSymbolsRounded.ttf"
fetch "$mdi/variablefont/MaterialSymbolsSharp%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf" "$MATERIALSYMBOLS_SHARP_SHA256" "MaterialSymbolsSharp.ttf"
fetch "$mdi/LICENSE" "$MATERIALSYMBOLS_LICENSE_SHA256" "MaterialSymbols-LICENSE.txt"
fetch "https://github.com/ryanoasis/nerd-fonts/releases/download/$JBM_RELEASE/JetBrainsMono.tar.xz" "$JETBRAINSMONO_NF_SHA256" "JetBrainsMono.tar.xz"
fetch "https://raw.githubusercontent.com/JetBrains/JetBrainsMono/$JBM_OFL_REF/OFL.txt" "$JETBRAINSMONO_OFL_SHA256" "JetBrainsMono-OFL.txt"
