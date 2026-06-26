FROM rockylinux:8

RUN dnf update -y && \
    dnf install -y \
        sudo \
        git \
        curl \
        wget \
        vim \
        which \
        tar \
        gzip \
        dnf-plugins-core \
    && dnf clean all

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID -m $USERNAME && \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER $USERNAME