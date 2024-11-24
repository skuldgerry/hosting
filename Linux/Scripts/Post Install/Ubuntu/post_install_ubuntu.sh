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
read -p "Set Fish shell as default for all users (a) or specific users (s)? " shell_choice
if [[ $shell_choice == "a" ]]; then
    for user_home in /home/*; do
        user=$(basename "$user_home")
        chsh -s /usr/bin/fish "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
    done
elif [[ $shell_choice == "s" ]]; then
    for user_home in /home/*; do
        user=$(basename "$user_home")
        read -p "Set Fish as default for $user? (y/n): " user_shell
        if [[ $user_shell =~ ^[Yy]$ ]]; then
            chsh -s /usr/bin/fish "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
        fi
    done
fi

# Tool Installation
echo -e "${CYAN}Installing tools using Nala...${RESET}"
apt install -y nala && {
    nala install -y lsd ranger gdu bat duf || echo -e "${RED}Failed to install some tools.${RESET}"
} || echo -e "${RED}Failed to install Nala.${RESET}"

# Custom Fish Functions
read -p "Install custom Fish functions? (y/n): " install_functions
if [[ $install_functions =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Downloading custom Fish functions from GitHub...${RESET}"
    temp_dir=$(mktemp -d)
    wget -q -r -nH --cut-dirs=3 --no-parent --reject "index.html*" \
        -P "$temp_dir" https://github.com/skuldgerry/hosting/raw/main/Linux/Fish_Functions/ || {
        echo -e "${RED}Failed to download Fish functions.${RESET}"
        rm -rf "$temp_dir"
        exit 1
    }

    echo -e "${CYAN}Installing Fish functions...${RESET}"
    mkdir -p /usr/share/fish/functions/
    cp -r "$temp_dir"/* /usr/share/fish/functions/ || {
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

# Final Summary
echo -e "\n${CYAN}Summary of Actions:${RESET}"
echo -e "${GREEN}✔ System updated${RESET}"
echo -e "${GREEN}✔ Custom repository added${RESET}"
[[ $install_qemu =~ ^[Yy]$ ]] && echo -e "${GREEN}✔ QEMU Guest Agent installed${RESET}"
[[ $install_prometheus =~ ^[Yy]$ ]] && echo -e "${GREEN}✔ Prometheus Node Exporter installed${RESET}"
[[ $install_functions =~ ^[Yy]$ ]] && echo -e "${GREEN}✔ Custom Fish functions installed${RESET}"
echo -e "${GREEN}✔ Tools installed: nala, lsd, ranger, gdu, bat, duf${RESET}"
echo -e "\n${GREEN}Post-install setup completed successfully!${RESET}"
