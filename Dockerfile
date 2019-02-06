FROM debian:stretch as openssl-builder

ENV version_openssl=openssl-1.1.1a \
    sha256_openssl=fc20130f8b7cbd2fb918b2f14e2f429e109c31ddd0fb38fc5d71d9ffed3f9f41 \
    source_openssl=https://www.openssl.org/source/ 

WORKDIR /tmp/src

RUN set -e -x && \
    build_deps="build-essential ca-certificates curl dirmngr gnupg libidn2-0-dev libssl-dev" && \
    debian_frontend=noninteractive apt-get update && apt-get install -y --no-install-recommends \
      $build_deps && \
    curl -L "${source_openssl}${version_openssl}.tar.gz" -o openssl.tar.gz && \
    echo "${sha256_openssl} ./openssl.tar.gz" | sha256sum -c - && \
    tar xzf openssl.tar.gz && \
    cd "$version_openssl" && \
    ./config --prefix=/opt/openssl no-weak-ssl-ciphers no-ssl3 no-shared enable-ec_nistp_64_gcc_128 -DOPENSSL_NO_HEARTBEATS -fstack-protector-strong && \
    make depend && \
    make && \
    make install_sw && \
    apt-get purge -y --auto-remove \
      $build_deps && \
    rm -rf \
      /tmp/* \
      /var/tmp/* \
      /var/lib/apt/lists/*

#######
# unbound builder
#######
FROM debian:stretch as unbound-builder

ENV unbound_version=1.8.3 \
    unbound_sha256=2b692b8311edfad41e7d0380aac34576060d4176add81dc5db419c79b2a4cecc \
    unbound_download_url="https://nlnetlabs.nl/downloads/unbound/unbound-1.8.3.tar.gz"

WORKDIR /tmp/src

COPY --from=openssl-builder /opt/openssl /opt/openssl

RUN build_deps="ca-certificates curl gcc libc-dev libevent-dev libexpat1-dev make" && \
    set -x && \
    debian_frontend=noninteractive apt-get update && apt-get install -y --no-install-recommends \
      $build_deps \
      bsdmainutils \
      ldnsutils \
      libevent-2.0 \
      libexpat1 && \
    curl -sSL "${unbound_download_url}" -o unbound.tar.gz && \
    echo "${unbound_sha256} *unbound.tar.gz" | sha256sum -c - && \
    tar xzf unbound.tar.gz && \
    rm -f unbound.tar.gz && \
    cd unbound-"${unbound_version}" && \
    groupadd _unbound && \
    useradd -g _unbound -s /etc -d /dev/null _unbound && \
    ./configure \
        --disable-dependency-tracking \
        --prefix=/opt/unbound \
        --with-pthreads \
        --with-username=_unbound \
        --with-ssl=/opt/openssl \
        --with-libevent \
        --enable-event-api && \
    make install && \
    mv /opt/unbound/etc/unbound/unbound.conf /opt/unbound/etc/unbound/unbound.conf.example && \
    apt-get purge -y --auto-remove \
      $build_deps && \
    rm -fr \
      /opt/unbound/share/man \
      /tmp/* \
      /var/tmp/* \
      /var/lib/apt/lists/*

#########
# Result
#########
FROM debian:stretch

EXPOSE 53/udp
COPY --from=openssl-builder /opt/openssl /opt/openssl

WORKDIR /tmp/src

########
# Stubby
########

RUN set -e -x && \
    build_deps="autoconf build-essential dh-autoreconf git libssl-dev libtool-bin libyaml-dev make m4" && \
    debian_frontend=noninteractive apt-get update && apt-get install -y --no-install-recommends \
      $build_deps \
      ca-certificates \
      dns-root-data \
      ldnsutils \
      libev4 \
      libevent-core-2.0.5 \
      libidn11 \
      libuv1 \
      libyaml-0-2 && \
    git clone https://github.com/getdnsapi/getdns.git --branch develop && \
    cd getdns && \
    git submodule update --init && \
    libtoolize -ci && \
    autoreconf -fi && \
    mkdir build && \
    cd build && \
    ../configure --prefix=/opt/stubby --without-libidn --without-libidn2 --enable-stub-only --with-ssl=/opt/openssl --with-stubby && \
    make && \
    make install && \
    groupadd -r stubby && \
    useradd --no-log-init -r -g stubby stubby && \
    apt-get purge -y --auto-remove \
      $build_deps && \
    rm -rf \
      /tmp/* \
      /var/tmp/* \
      /var/lib/apt/lists/*

COPY stubby/stubby.yml /opt/stubby/etc/stubby/stubby.yml

#########
# Unbound
#########
ENV name=unbound \
    unbound_version=1.8.3 \
    version=1.1

ENV summary="${name} is a validating, recursive, and caching DNS resolver." \
    description="${name} is a validating, recursive, and caching DNS resolver."

LABEL summary="${summary}" \
      description="${description}" \
      io.k8s.description="${description}" \
      io.k8s.display-name="Unbound ${unbound_version}" \
      name="mvance/${name}" 

WORKDIR /tmp/src

COPY --from=unbound-builder /opt/ /opt/

RUN set -x && \
    debian_frontend=noninteractive apt-get update && apt-get install -y --no-install-recommends \
      bsdmainutils \
      ldnsutils \
      libevent-2.0 \
      libexpat1 && \
    groupadd _unbound && \
    useradd -g _unbound -s /etc -d /dev/null _unbound && \
   rm -fr \
      /tmp/* \
      /var/tmp/* \
      /var/lib/apt/lists/*

COPY unbound/a-records.conf /opt/unbound/etc/unbound/
COPY unbound/unbound.sh /

RUN chmod +x /unbound.sh


########
# Wrapup
########
WORKDIR /opt

ENV PATH /opt/unbound/sbin:/opt/stubby/bin:$PATH

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s CMD drill @127.0.0.1 cloudflare.com || exit 1

COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
