FROM container-registry.oracle.com/olcne/ock:base-image
COPY rpms /tmp/
RUN dnf install -y /tmp/*.rpm &&\
    dnf clean all &&\
    rm -rf /var/cache/yum/* /tmp/*.rpm

FROM container-registry.oracle.com/olcne/ock:base-image
COPY --from=0 /usr/share/licenses/coredns* /usr/share/licenses/
COPY --from=0 /usr/bin/coredns /usr/bin/coredns
RUN dnf install -y bind-utils ca-certificates openssl &&\
    dnf clean all &&\
    rm -rf /var/cache/yum/* /tmp/* &&\
    ln -s /usr/share/licenses /LICENSES

EXPOSE 53 53/udp

ENTRYPOINT ["/usr/bin/coredns"]
