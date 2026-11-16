%{!?snapdate:%{error:snapdate is not defined}}
%{!?gf_ref:%{error:gf_ref is not defined}}
%{!?mdi_ref:%{error:mdi_ref is not defined}}
%{!?jbm_release:%{error:jbm_release is not defined}}
%{!?jbm_ofl_ref:%{error:jbm_ofl_ref is not defined}}
%global debug_package %{nil}
%global gf https://raw.githubusercontent.com/google/fonts/%{gf_ref}
%global mdi https://raw.githubusercontent.com/google/material-design-icons/%{mdi_ref}

Name:           microos-fonts
Version:        0^%{snapdate}
Release:        1%{?dist}.microos
Summary:        Fonts for the MicroOS desktop shell
License:        OFL-1.1 AND Apache-2.0
URL:            https://github.com/seilent/MicroOS
Source0:        %{gf}/ofl/spacegrotesk/SpaceGrotesk[wght].ttf#/SpaceGrotesk.ttf
Source1:        %{gf}/ofl/readexpro/ReadexPro[HEXP,wght].ttf#/ReadexPro.ttf
Source2:        %{gf}/ofl/rubik/Rubik[wght].ttf#/Rubik.ttf
Source3:        %{gf}/ofl/rubik/Rubik-Italic[wght].ttf#/Rubik-Italic.ttf
Source4:        %{gf}/ofl/googlesansflex/GoogleSansFlex[ROND,opsz,slnt,wdth,wght].ttf#/GoogleSansFlex.ttf
Source5:        %{mdi}/variablefont/MaterialSymbolsOutlined[FILL,GRAD,opsz,wght].ttf#/MaterialSymbolsOutlined.ttf
Source6:        %{mdi}/variablefont/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf#/MaterialSymbolsRounded.ttf
Source7:        %{mdi}/variablefont/MaterialSymbolsSharp[FILL,GRAD,opsz,wght].ttf#/MaterialSymbolsSharp.ttf
Source8:        https://github.com/ryanoasis/nerd-fonts/releases/download/%{jbm_release}/JetBrainsMono.tar.xz
Source20:       %{gf}/ofl/spacegrotesk/OFL.txt#/SpaceGrotesk-OFL.txt
Source21:       %{gf}/ofl/readexpro/OFL.txt#/ReadexPro-OFL.txt
Source22:       %{gf}/ofl/rubik/OFL.txt#/Rubik-OFL.txt
Source23:       %{gf}/ofl/googlesansflex/OFL.txt#/GoogleSansFlex-OFL.txt
Source24:       %{mdi}/LICENSE#/MaterialSymbols-LICENSE.txt
Source25:       https://raw.githubusercontent.com/JetBrains/JetBrainsMono/%{jbm_ofl_ref}/OFL.txt#/JetBrainsMono-OFL.txt
Vendor:         MicroOS
BuildArch:      noarch
BuildRequires:  fontconfig
BuildRequires:  tar
BuildRequires:  xz

%description
The fonts the MicroOS desktop shell draws with: Material Symbols
(Outlined, Rounded, Sharp), Google Sans Flex, Space Grotesk, Readex Pro,
Rubik and JetBrains Mono Nerd Font.

%prep
%setup -q -c -T

%build

%check
check_font() {
  local fam
  fam=$(fc-scan --format '%{family}\n' "$1" | head -n1)
  [[ -n $fam ]] || { echo "check: $1 has no family name" >&2; exit 1; }
  printf '%s\t%s\n' "$fam" "$1"
}
for f in %{SOURCE0} %{SOURCE1} %{SOURCE2} %{SOURCE3} %{SOURCE4} %{SOURCE5} %{SOURCE6} %{SOURCE7}; do
  check_font "$f"
done
jbm=$(mktemp -d)
tar -xJf %{SOURCE8} -C "$jbm" \
  JetBrainsMonoNerdFont-Regular.ttf JetBrainsMonoNerdFont-Bold.ttf \
  JetBrainsMonoNerdFont-Italic.ttf JetBrainsMonoNerdFont-BoldItalic.ttf
n=0
for f in "$jbm"/*.ttf; do
  check_font "$f"
  n=$((n + 1))
done
[[ $n -eq 4 ]] || { echo "check: expected 4 JetBrains Mono NF fonts, got $n" >&2; exit 1; }
rm -rf "$jbm"

%install
install -D -pm644 %{SOURCE0} "%{buildroot}%{_datadir}/fonts/space-grotesk/SpaceGrotesk[wght].ttf"
install -D -pm644 %{SOURCE1} "%{buildroot}%{_datadir}/fonts/readex-pro/ReadexPro[HEXP,wght].ttf"
install -D -pm644 %{SOURCE2} "%{buildroot}%{_datadir}/fonts/rubik/Rubik[wght].ttf"
install -D -pm644 %{SOURCE3} "%{buildroot}%{_datadir}/fonts/rubik/Rubik-Italic[wght].ttf"
install -D -pm644 %{SOURCE4} "%{buildroot}%{_datadir}/fonts/google-sans-flex/GoogleSansFlex[ROND,opsz,slnt,wdth,wght].ttf"
install -D -pm644 %{SOURCE5} "%{buildroot}%{_datadir}/fonts/material-symbols/MaterialSymbolsOutlined[FILL,GRAD,opsz,wght].ttf"
install -D -pm644 %{SOURCE6} "%{buildroot}%{_datadir}/fonts/material-symbols/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf"
install -D -pm644 %{SOURCE7} "%{buildroot}%{_datadir}/fonts/material-symbols/MaterialSymbolsSharp[FILL,GRAD,opsz,wght].ttf"

install -d %{buildroot}%{_datadir}/fonts/jetbrains-mono-nf
tar -xJf %{SOURCE8} -C %{buildroot}%{_datadir}/fonts/jetbrains-mono-nf \
  JetBrainsMonoNerdFont-Regular.ttf JetBrainsMonoNerdFont-Bold.ttf \
  JetBrainsMonoNerdFont-Italic.ttf JetBrainsMonoNerdFont-BoldItalic.ttf
chmod 644 %{buildroot}%{_datadir}/fonts/jetbrains-mono-nf/*.ttf

install -D -pm644 %{SOURCE20} %{buildroot}%{_licensedir}/microos-fonts/SpaceGrotesk-OFL.txt
install -D -pm644 %{SOURCE21} %{buildroot}%{_licensedir}/microos-fonts/ReadexPro-OFL.txt
install -D -pm644 %{SOURCE22} %{buildroot}%{_licensedir}/microos-fonts/Rubik-OFL.txt
install -D -pm644 %{SOURCE23} %{buildroot}%{_licensedir}/microos-fonts/GoogleSansFlex-OFL.txt
install -D -pm644 %{SOURCE24} %{buildroot}%{_licensedir}/microos-fonts/MaterialSymbols-LICENSE.txt
install -D -pm644 %{SOURCE25} %{buildroot}%{_licensedir}/microos-fonts/JetBrainsMono-OFL.txt

%files
%license %{_licensedir}/microos-fonts/SpaceGrotesk-OFL.txt
%license %{_licensedir}/microos-fonts/ReadexPro-OFL.txt
%license %{_licensedir}/microos-fonts/Rubik-OFL.txt
%license %{_licensedir}/microos-fonts/GoogleSansFlex-OFL.txt
%license %{_licensedir}/microos-fonts/MaterialSymbols-LICENSE.txt
%license %{_licensedir}/microos-fonts/JetBrainsMono-OFL.txt
%{_datadir}/fonts/space-grotesk/
%{_datadir}/fonts/readex-pro/
%{_datadir}/fonts/rubik/
%{_datadir}/fonts/google-sans-flex/
%{_datadir}/fonts/material-symbols/
%{_datadir}/fonts/jetbrains-mono-nf/

%changelog
