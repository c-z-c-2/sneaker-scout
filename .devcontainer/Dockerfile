FROM python:3.11-slim

# Install uv (fast Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install system dependencies: Chromium, Node.js, and dev tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    chromium-driver \
    fonts-liberation \
    libnss3 \
    libxss1 \
    libasound2 \
    libatk-bridge2.0-0 \
    libgtk-3-0 \
    curl \
    git \
    sudo \
    zsh \
    && rm -rf /var/lib/apt/lists/* \
    && curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# Create non-root user matching host UID/GID
ARG USERNAME=chris
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /usr/bin/zsh $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$USERNAME

# Install Oh My Zsh + plugins for chris
USER chris
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions \
    && git clone https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting \
    && sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc
USER root

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Chrome/Selenium env vars
ENV CHROME_BIN=/usr/bin/chromium
ENV CHROMEDRIVER_PATH=/usr/bin/chromedriver

# undetected_chromedriver patches the binary in-place — needs write access for non-root users
RUN chmod a+rw /usr/bin/chromedriver

WORKDIR /workspace

# Python deps are installed via `uv sync` in postCreateCommand after the workspace is mounted.
# This keeps the image lean and means dep changes don't require a full image rebuild.

# Install Node dependencies (will be overwritten by mount, but cached in image for speed)
COPY aussie-kicks-tracker/package.json aussie-kicks-tracker/package-lock.json /tmp/frontend/
RUN cd /tmp/frontend && npm ci

ENV PYTHONPATH=/workspace
