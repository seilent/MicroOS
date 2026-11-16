%{!?commit:%{error:commit is not defined}}
%{!?snapdate:%{error:snapdate is not defined}}

Name:           audioreach-topology
Version:        0^%{snapdate}git%{lua:print(rpm.expand("%{commit}"):sub(1, 10))}
Release:        1%{?dist}.microos
Summary:        AudioReach topology for the Lenovo Legion Y700 (2025)
License:        BSD-3-Clause
URL:            https://git.codelinaro.org/linaro/qcomlt/audioreach-topology
Source0:        %{url}/-/archive/%{commit}/%{name}-%{commit}.tar.gz
Source1:        LICENSE.audioreach-topology
Patch0:         0001-audioreach-add-legacy-tdm-sink-module.patch
Patch1:         0002-audioreach-add-tplg-for-lenovo-legion-y700-2025.patch
Vendor:         MicroOS
BuildArch:      noarch
BuildRequires:  m4
BuildRequires:  alsa-topology-utils

%description
AudioReach topology for the Lenovo Legion Y700 (2025), TB321FU: speakers on
Secondary TDM0, headset on RX_CODEC_DMA_RX_0, capture on VA_CODEC_DMA_TX_0
and TX_CODEC_DMA_TX_3, built from the audioreach-topology m4 macros.

%prep
%autosetup -p1 -n %{name}-%{commit}
cp %{SOURCE1} LICENSE

%build
m4 -I . SM8650-LENOVO-TB321FU.m4 > Lenovo-Y700-TB321FU.conf
alsatplg -c Lenovo-Y700-TB321FU.conf -o Lenovo-Y700-TB321FU-tplg.bin

%install
install -D -m 0644 Lenovo-Y700-TB321FU-tplg.bin \
  %{buildroot}%{_prefix}/lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin

%files
%license LICENSE
%{_prefix}/lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin
