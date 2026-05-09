FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

RUN sed -i 's|http://ports.ubuntu.com/ubuntu-ports|http://mirrors.ustc.edu.cn/ubuntu-ports|g' /etc/apt/sources.list && \
    sed -i 's|http://archive.ubuntu.com/ubuntu|http://mirrors.ustc.edu.cn/ubuntu|g' /etc/apt/sources.list && \
    sed -i 's|http://security.ubuntu.com/ubuntu|http://mirrors.ustc.edu.cn/ubuntu|g' /etc/apt/sources.list

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    gcc-arm-none-eabi \
    make \
    cmake \
    python3 \
    python3-pip \
    bc \
    bison \
    flex \
    libssl-dev \
    libncurses-dev \
    libelf-dev \
    device-tree-compiler \
    git \
    git-lfs \
    wget \
    curl \
    xz-utils \
    unzip \
    rsync \
    qemu-user-static \
    binfmt-support \
    e2fsprogs \
    dosfstools \
    ca-certificates \
    cpio \
    mtd-utils \
    u-boot-tools \
    gcc \
    g++ \
    ruby \
    mtools \
    genext2fs \
    gperf \
    libffi-dev \
    libgl1-mesa-dev \
    libxml2-dev \
    xsltproc \
    libdwarf-dev \
    kmod \
    squashfs-tools \
    libncurses5 \
    libncurses5-dev \
    libstdc++6 \
    vim \
    ssh \
    locales \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/bin/python3 /usr/bin/python
RUN rm -f /bin/sh && ln -s /bin/bash /bin/sh

RUN pip3 install requests setuptools pycryptodome ecdsa pyyaml six

ENV CROSS_COMPILE=aarch64-linux-gnu-
ENV ARCH=arm64
ENV CC=aarch64-linux-gnu-gcc
ENV CXX=aarch64-linux-gnu-g++

WORKDIR /workspace
