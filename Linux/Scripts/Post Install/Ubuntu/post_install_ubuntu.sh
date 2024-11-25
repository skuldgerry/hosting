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
dialog --title "QEMU Guest Agent" --yesno "Install QEMU Guest Agent?" 7 60
if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}Installing QEMU Guest Agent...${RESET}"
    apt install -y qemu-guest-agent || echo -e "${RED}Failed to install QEMU Guest Agent.${RESET}"
fi

# Prompt for Prometheus Node Exporter
dialog --title "Prometheus Node Exporter" --yesno "Install Prometheus Node Exporter?" 7 60
if [[ $? -eq 0 ]]; then
    echo -e "${CYAN}Installing Prometheus Node Exporter...${RESET}"
    apt install -y prometheus-node-exporter || {
        echo -e "${RED}Failed to install Node Exporter.${RESET}"
        exit 1
    }
    echo -e "${GREEN}Prometheus Node Exporter installed and configured successfully!${RESET}"
fi

# Shell Setup: Install Fish shell globally
echo -e "${CYAN}Installing Fish shell globally...${RESET}"
apt install -y fish || echo -e "${RED}Failed to install Fish shell.${RESET}"

# Install Fisher globally for all users
echo -e "${CYAN}Installing Fisher globally for all users...${RESET}"
curl -sL https://git.io/fisher | fish > /dev/null 2>&1
fish -c "fisher install jorgebucaran/fisher"

# Install Tide globally for all users
echo -e "${CYAN}Installing Tide globally for all users...${RESET}"
fish -c "fisher install IlanCosman/tide"

# Ensure the Tide configuration is available to all users
echo -e "${CYAN}Configuring Tide for root and copying configuration to all users...${RESET}"
cp -r /root/.config/tide/ /etc/skel/.config/tide/ || echo -e "${RED}Failed to copy Tide config to /etc/skel.${RESET}"

# Shell Setup: Configure Fish for users
tide_config_choice=$(dialog --menu "Tide Configuration" 15 60 3 \
    1 "Install Tide for selected users" \
    2 "Skip Tide install" \
    3>&1 1>&2 2>&3)
clear

if [[ $tide_config_choice == "1" ]]; then
    # List available users
    users=$(getent passwd | cut -d: -f1)
    selected_users=$(dialog --title "Select Users" --checklist "Select users to install Tide" 15 60 8 \
    $(for user in $users; do echo "$user" "$user" off; done) 3>&1 1>&2 2>&3)
    clear

    for user in $selected_users; do
        user_home="/home/$user"
        # Copy Tide configuration to the user's home directory
        cp -r /root/.config/tide/ "$user_home/.config/" || echo -e "${RED}Failed to copy Tide config to $user.${RESET}"
    done
fi

# Prompt for Fish as the default shell
shell_choice=$(dialog --menu "Set Fish shell as default for users" 15 60 3 \
    1 "All users" \
    2 "Specific users" \
    3 "Skip" \
    3>&1 1>&2 2>&3)
clear

if [[ $shell_choice == "1" ]]; then
    for user_home in /home/*; do
        user=$(basename "$user_home")
        chsh -s /usr/bin/fish "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
    done
elif [[ $shell_choice == "2" ]]; then
    # List available users
    users=$(getent passwd | cut -d: -f1)
    selected_users=$(dialog --title "Select Users" --checklist "Select users to set Fish as default shell" 15 60 8 \
    $(for user in $users; do echo "$user" "$user" off; done) 3>&1 1>&2 2>&3)
    clear

    for user in $selected_users; do
        chsh -s /usr/bin/fish "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
    done
fi

# Tool Installation
echo -e "${CYAN}Installing tools using Nala...${RESET}"
apt install -y nala && {
    nala install -y lsd ranger gdu bat duf || echo -e "${RED}Failed to install some tools.${RESET}"
} || echo -e "${RED}Failed to install Nala.${RESET}"

# Custom Fish Functions Installation
dialog --title "Custom Fish Functions" --yesno "Install custom Fish functions?" 7 60
if [[ $? -eq 0 ]]; then
    echo -e "${CYAN}Cloning custom Fish functions from GitHub...${RESET}"
    
    # Temporary directory for cloning the functions
    temp_dir=$(mktemp -d)

    # Clone only the Fish functions directory from GitHub
    git clone --depth 1 --single-branch --branch main \
        "https://github.com/skuldgerry/hosting.git" "$temp_dir" || {
        echo -e "${RED}Failed to clone Fish functions from GitHub.${RESET}"
        rm -rf "$temp_dir"
        exit 1
    }

    # Ensure the fish functions are in the correct directory
    fish_functions_dir="$temp_dir/Linux/Fish_Functions"

    if [[ -d "$fish_functions_dir" ]]; then
        echo -e "${CYAN}Installing Fish functions system-wide...${RESET}"
        
        # Move the functions to the system-wide Fish functions directory
        mkdir -p /usr/share/fish/functions/
        cp -r "$fish_functions_dir"/* /usr/share/fish/functions/ || {
            echo -e "${RED}Failed to copy Fish functions to system-wide directory.${RESET}"
            rm -rf "$temp_dir"
            exit 1
        }
    else
        echo -e "${RED}Fish functions directory not found.${RESET}"
        rm -rf "$temp_dir"
        exit 1
    fi

    # Continue with user selection for installing functions
    user_choice=$(dialog --menu "Install Fish functions for" 15 60 3 \
        1 "All users" \
        2 "Specific users" \
        3 "Skip" \
        3>&1 1>&2 2>&3)
    clear

    if [[ $user_choice == "1" ]]; then
        echo -e "${GREEN}Functions are already available system-wide in /usr/share/fish/functions/${RESET}"
    elif [[ $user_choice == "2" ]]; then
        users=$(getent passwd | cut -d: -f1)
        selected_users=$(dialog --title "Select Users" --checklist "Select users to install functions" 15 60 8 \
        $(for user in $users; do echo "$user" "$user" off; done) 3>&1 1>&2 2>&3)
        clear

        for user in $selected_users; do
            user_home="/home/$user"
            mkdir -p "$user_home/.config/fish/functions"
            cp -r /usr/share/fish/functions/* "$user_home/.config/fish/functions/"
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
