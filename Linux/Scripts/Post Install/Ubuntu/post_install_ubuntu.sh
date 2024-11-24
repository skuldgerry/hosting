#!/bin/bash

# Colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
RESET="\033[0m"

# Header function
header_info() {
  clear
  cat <<"EOF"
    ____  ____ _____    _    _       _   _  _____ _____  _____ _____ ______ 
   / __ \/ __ ) ___/   | |  | |     | | | ||  ___|  __ \|_   _/  __ \| ___ \
  / /_/ / __  \__ \    | |  | |_ __ | |_| || |__ | |  \/  | | | /  \/| |_/ /
 / ____/ /_/ /__/ /    | |/\| | '_ \|  _  ||  __|| | __   | | | |    |    / 
/_/   /_____/____/     \  /\  / | | | | | || |___| |_\ \ _| |_| \__/\| |\ \ 
                       \/  \/|_| |_|_| |_/\____/ \____/ \___/ \____/\_| \_|

                     Ubuntu Server Post Install Script
EOF
}

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root. Exiting.${RESET}"
    exit 1
fi

header_info

# Basic Linux Setup
echo -e "${CYAN}Updating system...${RESET}"
apt update && apt upgrade -y && apt dist-upgrade -y || {
  echo -e "${RED}System update failed. Exiting.${RESET}"
  exit 1
}

# Define repository details
CUSTOM_REPO_URL="https://raw.githubusercontent.com/skuldgerry/hosting/main/Linux/Scripts/Post%20Install/Ubuntu/Repo"
CUSTOM_REPO_NAME="custom-tools"

# Add custom repo
echo -e "${CYAN}Adding custom repository for tools...${RESET}"
echo "deb [trusted=yes] ${CUSTOM_REPO_URL} ./" > /etc/apt/sources.list.d/${CUSTOM_REPO_NAME}.list

# Validate and update
apt update || {
    echo -e "${RED}Failed to add custom repository. Please check the URL or structure.${RESET}"
    exit 1
}
echo -e "${GREEN}Custom repository added successfully!${RESET}"

# Prompt for QEMU Guest Agent
read -p "Install QEMU Guest Agent? (y/n): " install_qemu
if [[ $install_qemu =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Installing QEMU Guest Agent...${RESET}"
    apt install -y qemu-guest-agent || echo -e "${RED}Failed to install QEMU Guest Agent.${RESET}"
fi

# Prompt for Prometheus Node Exporter
read -p "Install and configure Prometheus Node Exporter as a service? (y/n): " install_prometheus
if [[ $install_prometheus =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Installing Prometheus Node Exporter...${RESET}"
    apt install -y prometheus-node-exporter || {
        echo -e "${RED}Failed to install Node Exporter.${RESET}"
        exit 1
    }

    echo -e "${CYAN}Configuring Node Exporter as a systemd service...${RESET}"
    cat <<EOF >/etc/systemd/system/node-exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node-exporter
    systemctl start node-exporter || echo -e "${RED}Failed to start Node Exporter service.${RESET}"
fi

# Shell Setup
echo -e "${CYAN}Installing Fish shell and Fisher...${RESET}"
apt install -y fish || echo -e "${RED}Failed to install Fish shell.${RESET}"
fish -c "curl -sL https://git.io/fisher | source && fisher install jorgebucaran/fisher"
fish -c "fisher install IlanCosman/tide && tide configure"

echo -e "${CYAN}Setting default shell to Fish...${RESET}"
chsh -s /usr/bin/fish $(whoami) || echo -e "${RED}Failed to set Fish as default shell.${RESET}"

# Tool Installation
echo -e "${CYAN}Installing tools...${RESET}"
apt install -y nala lsd ranger gdu bat duf || echo -e "${RED}Failed to install tools.${RESET}"

# Custom Fish Functions
read -p "Install custom Fish functions? (y/n): " install_functions
if [[ $install_functions =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Downloading custom Fish functions from GitHub...${RESET}"
    temp_dir=$(mktemp -d)

    # Clone the GitHub repository (requires git)
    if command -v git &> /dev/null; then
        git clone --depth 1 https://github.com/skuldgerry/hosting.git "$temp_dir" || {
            echo -e "${RED}Failed to clone Fish functions from GitHub.${RESET}"
            rm -rf "$temp_dir"
            exit 1
        }
    else
        # Fallback to wget or curl if git is not available
        wget -q -P "$temp_dir" https://raw.githubusercontent.com/skuldgerry/hosting/main/Linux/Fish_Functions/* || {
            echo -e "${RED}Failed to download Fish functions from GitHub.${RESET}"
            rm -rf "$temp_dir"
            exit 1
        }
    fi

    # Copy Fish functions
    echo -e "${CYAN}Installing Fish functions...${RESET}"
    mkdir -p /usr/share/fish/functions/
    cp -r "$temp_dir/Linux/Fish_Functions/"* /usr/share/fish/functions/ || {
        echo -e "${RED}Failed to copy Fish functions.${RESET}"
        rm -rf "$temp_dir"
        exit 1
    }

    # Prompt for user-specific installation
    read -p "Install for all users (a) or specific users (s)? " user_choice
    if [[ $user_choice == "a" ]]; then
        echo -e "${GREEN}Installing functions for all users...${RESET}"
        cp -r /usr/share/fish/functions/* /etc/skel/.config/fish/functions/
        for user_home in /home/*; do
            cp -r /usr/share/fish/functions/* "$user_home/.config/fish/functions/"
        done
    elif [[ $user_choice == "s" ]]; then
        for user_home in /home/*; do
            user=$(basename "$user_home")
            read -p "Install for $user? (y/n): " user_install
            if [[ $user_install =~ ^[Yy]$ ]]; then
                mkdir -p "$user_home/.config/fish/functions"
                cp -r /usr/share/fish/functions/* "$user_home/.config/fish/functions/"
            fi
        done
    fi

    # Cleanup
    rm -rf "$temp_dir"
else
    echo -e "${CYAN}Skipping Fish functions installation.${RESET}"
fi

echo -e "${GREEN}Post-install setup completed successfully!${RESET}"
