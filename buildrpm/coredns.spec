{{{$version := printf "%s.%s.%s" .major .minor .patch }}}
%global with_debug 0

%if 0%{?with_debug}
# https://bugzilla.redhat.com/show_bug.cgi?id=995136#c12
%global _dwz_low_mem_die_limit 0
%else
%global debug_package   %{nil}
%endif

%global build_dir       src/github.com/coredns/coredns
%global _buildhost	build-ol%{?oraclelinux}-%{?_arch}.oracle.com

Name:           coredns
Version:        {{{$version}}}
Release:        1%{?dist}
Summary:        DNS and Service Discovery
License:        Apache-2.0
Group:          System/Management
Url:            https://github.com/coredns/coredns
Source:         %{name}-%{version}.tar.bz2
Vendor:         Oracle America
BuildRequires:  golang
BuildRequires:  jq

%description
CoreDNS is a DNS server.
It can be used in a multitude of environments because of its flexibility.
CoreDNS chains plugins. Each plugin performs a DNS function, such as
Kubernetes service discovery, Prometheus metrics or rewriting queries.
And many more.

%prep
%setup -q -n coredns-%{version}
mkdir -p %{build_dir}
mv $(ls | grep -v "^src$") %{build_dir}
{{{- if semverCompare ">1.11.2" $version }}}
mv .go-version %{build_dir}
{{{- end }}}

%build
unset GOPROXY
pushd %{build_dir}
GIT_COMMIT_SHA=$(curl -s https://api.github.com/repos/coredns/coredns/git/refs/tags/v{{{$version}}} | jq -r '.object.sha[0:7]')
{{{- if semverCompare ">1.11.2" $version }}}
GOLANG_VERSION=$(cat .go-version)
{{{- end }}}
make GITCOMMIT=${GIT_COMMIT_SHA}

popd

%install
install -D -p -m 0755 %{build_dir}/coredns %{buildroot}%{_bindir}/%{name}
mv %{build_dir}/LICENSE .
mv %{build_dir}/THIRD_PARTY_LICENSES.txt .

%files
%license LICENSE THIRD_PARTY_LICENSES.txt
%{_bindir}/%{name}

%changelog
* {{{.changelog_timestamp}}} - {{{$version}}}-1
- Added Oracle specific build files
