FROM rockylinux:8.10

# 基础工具
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
    && dnf clean all

# 创建非 root 用户（Codespaces 要求）
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID -m $USERNAME && \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER $USERNAME