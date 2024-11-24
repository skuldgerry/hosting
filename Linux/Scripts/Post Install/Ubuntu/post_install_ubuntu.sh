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

# Trap to handle unexpected errors
trap 'echo -e "${RED}An unexpected error occurred. Exiting.${RESET}"; exit 1' ERR

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

# Install dialog
apt install dialog -y

# Prompt for QEMU Guest Agent
read -p "Install QEMU Guest Agent? (y/n): " install_qemu
if [[ $install_qemu =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Installing QEMU Guest Agent...${RESET}"
    apt install -y qemu-guest-agent || echo -e "${RED}Failed to install QEMU Guest Agent.${RESET}"
fi

# Prompt for Prometheus Node Exporter
read -p "Install Prometheus Node Exporter? (y/n): " install_prometheus
if [[ $install_prometheus =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Installing Prometheus Node Exporter...${RESET}"
    apt install -y prometheus-node-exporter || {
        echo -e "${RED}Failed to install Node Exporter.${RESET}"
        exit 1
    }
    echo -e "${GREEN}Prometheus Node Exporter installed and configured successfully!${RESET}"
fi

# Shell Setup
echo -e "${CYAN}Installing Fish shell and Fisher...${RESET}"
apt install -y fish || echo -e "${RED}Failed to install Fish shell.${RESET}"
fish -c "curl -sL https://git.io/fisher | source && fisher install jorgebucaran/fisher"
fish -c "fisher install IlanCosman/tide && tide configure"

# Prompt for Fish as the default shell
echo -e "${CYAN}Set Fish shell as default for users:${RESET}"
echo "1) All users"
echo "2) Specific users"
echo "3) Skip"
read -p "Choose an option (1/2/3): " shell_choice
if [[ $shell_choice == "1" ]]; then
    for user_home in /home/*; do
        user=$(basename "$user_home")
        chsh -s /usr/bin/fish "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
    done
elif [[ $shell_choice == "2" ]]; then
    # List available users
    users=$(getent passwd | cut -d: -f1)
    echo "Select users to set Fish as default shell:"
    select user in $users; do
        if [[ -n "$user" ]]; then
            chsh -s /usr/bin/fish "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
        else
            echo -e "${RED}Invalid selection.${RESET}"
        fi
        break
    done
fi

# Tool Installation
echo -e "${CYAN}Installing tools using Nala...${RESET}"
apt install -y nala && {
    nala install -y lsd ranger gdu bat duf || echo -e "${RED}Failed to install some tools.${RESET}"
} || echo -e "${RED}Failed to install Nala.${RESET}"

# Custom Fish Functions Installation
echo -e "${CYAN}Install custom Fish functions? (y/n):${RESET}"
read -p "Choose (y/n): " install_functions
if [[ $install_functions =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Downloading custom Fish functions from GitHub...${RESET}"
    temp_dir=$(mktemp -d)
    wget -q -r -nH --cut-dirs=3 --no-parent --reject "index.html*" \
        -P "$temp_dir" https://github.com/skuldgerry/hosting/raw/main/Linux/Fish_Functions/ || {
        echo -e "${RED}Failed to download Fish functions.${RESET}"
        rm -rf "$temp_dir"
        exit 1
    }

    echo -e "${CYAN}Installing Fish functions system-wide...${RESET}"
    mkdir -p /usr/share/fish/functions/
    cp -r "$temp_dir"/* /usr/share/fish/functions/ || {
        echo -e "${RED}Failed to copy Fish functions.${RESET}"
        rm -rf "$temp_dir"
        exit 1
    }

    # User selection for function installation
    echo -e "${CYAN}Install Fish functions for:${RESET}"
    echo "1) All users"
    echo "2) Specific users"
    echo "3) Skip"
    read -p "Choose an option (1/2/3): " user_choice

    if [[ $user_choice == "1" ]]; then
        echo -e "${GREEN}Functions are already available system-wide in /usr/share/fish/functions/${RESET}"
        # No need to copy them to /etc/skel or user directories
    elif [[ $user_choice == "2" ]]; then
        for user_home in /home/*; do
            user=$(basename "$user_home")
            read -p "Install functions for $user? (y/n): " user_install
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

# Final Summary
echo -e "\n${CYAN}Summary of Actions:${RESET}"
echo -e "${GREEN}✔ System updated${RESET}"
[[ $install_qemu =~ ^[Yy]$ ]] && echo -e "${GREEN}✔ QEMU Guest Agent installed${RESET}"
[[ $install_prometheus =~ ^[Yy]$ ]] && echo -e "${GREEN}✔ Prometheus Node Exporter installed${RESET}"
[[ $install_functions =~ ^[Yy]$ ]] && echo -e "${GREEN}✔ Custom Fish functions installed${RESET}"
echo -e "${GREEN}✔ Tools installed: nala, lsd, ranger, gdu, bat, duf${RESET}"
echo -e "\n${GREEN}Post-install setup completed successfully!${RESET}"
