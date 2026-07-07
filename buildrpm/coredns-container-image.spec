
%if 0%{?with_debug}
# https://bugzilla.redhat.com/show_bug.cgi?id=995136#c12
%global _dwz_low_mem_die_limit 0
%else
%global debug_package   %{nil}
%endif

%{!?registry: %global registry container-registry.oracle.com/olcne}

%global _buildhost  build-ol%{?oraclelinux}-%{?_arch}.oracle.com
%global _name       coredns

Name:           %{_name}-container-image
Version:        1.14.3
Release:        1%{?dist}
Summary:        DNS and Service Discovery
License:        Apache-2.0
Group:          System/Management
Url:            https://github.com/coredns/coredns
Source:         %{name}-%{version}.tar.bz2
Vendor:         Oracle America

%description
CoreDNS is a DNS server.
It can be used in a multitude of environments because of its flexibility.
CoreDNS chains plugins. Each plugin performs a DNS function, such as
Kubernetes service discovery, Prometheus metrics or rewriting queries.
And many more.

%prep
%setup -q -n %{name}-%{version}

%build
%global rpm_name %{_name}-%{version}-%{release}.%{_build_arch}
yum clean all && yumdownloader --destdir=${PWD}/rpms %{rpm_name}

%__rm .dockerignore
%global docker_tag %{registry}/%{_name}:v%{version}
docker build --squash \
    --build-arg https_proxy=${https_proxy} \
    -t %{docker_tag} -f ./olm/builds/Dockerfile .
docker save -o %{_name}.tar %{docker_tag}

%install
%__install -D -m 644 %{_name}.tar %{buildroot}/usr/local/share/olcne/%{_name}.tar

%files
%license LICENSE
/usr/local/share/olcne/%{_name}.tar

%changelog
* Wed Apr 22 2026 Oracle Cloud Native Environment Authors <noreply@oracle.com> - 1.14.3-1
- Added Oracle specific build files
