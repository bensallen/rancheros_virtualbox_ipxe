FROM debian
LABEL MAINTAINER Spencer Brown

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get -y update && \
    apt-get -y install build-essential git liblzma-dev

RUN git clone git://git.ipxe.org/ipxe.git

WORKDIR /ipxe/src

# Remove unneeded features as VBox will only support a ROM that is 57344 bytes or less. Notably TFTP is disabled here. If TFTP and HTTP are needed DNS_RESOLVER can be disabled instead.
RUN /bin/echo -e '\n#undef DOWNLOAD_PROTO_TFTP\n#undef NET_PROTO_STP\n#undef NET_PROTO_LACP\n#undef VNIC_IPOIB\n#undef HTTP_AUTH_BASIC\n#undef HTTP_AUTH_DIGEST\n#undef SANBOOT_PROTO_HTTP' >> /ipxe/src/config/vbox/general.h

RUN make -j 4 CONFIG=vbox bin/virtio-net.isarom