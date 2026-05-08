FROM python:3.11-slim

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
    && rm -rf /var/lib/apt/lists/* \
    && curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# Create non-root user matching host UID/GID
ARG USERNAME=chris
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$USERNAME

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Chrome/Selenium env vars
ENV CHROME_BIN=/usr/bin/chromium
ENV CHROMEDRIVER_PATH=/usr/bin/chromedriver

WORKDIR /workspace

# Install Python dependencies
COPY sneaker-scout-backend/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Install Node dependencies (will be overwritten by mount, but cached in image for speed)
COPY aussie-kicks-tracker/package.json aussie-kicks-tracker/package-lock.json /tmp/frontend/
RUN cd /tmp/frontend && npm ci

ENV PYTHONPATH=/workspace
