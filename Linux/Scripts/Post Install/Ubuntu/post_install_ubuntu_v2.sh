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
 _____   _____   _____       _    _  ____   _    _  _   _  _______  _    _ 
|  __ \ |_   _| / ____|     | |  | ||  _ \ | |  | || \ | ||__   __|| |  | |
| |__) |  | |  | (___       | |  | || |_) || |  | ||  \| |   | |   | |  | |
|  ___/   | |   \___ \      | |  | ||  _ < | |  | || . ` |   | |   | |  | |
| |      _| |_  ____) |     | |__| || |_) || |__| || |\  |   | |   | |__| |
|_|     |_____||_____/       \____/ |____/  \____/ |_| \_|   |_|    \____/

                     Ubuntu Server Post Install Script
EOF
}

# Enable verbose mode if -v flag is passed
VERBOSE=0
while getopts "v" opt; do
  case $opt in
    v)
      VERBOSE=1
      ;;
  esac
done

# Run commands with optional verbosity
run_cmd() {
  if [ "$VERBOSE" -eq 1 ]; then
    "$@"
  else
    "$@" &>/dev/null
  fi
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
echo -e "\033[1;34m[INFO]\033[0m Updating system..."
apt update && apt upgrade -y && apt dist-upgrade -y || {
    echo -e "\033[31mSystem update failed. Exiting.\033[0m"
    exit 1
}

# Extend LVM partition to use full volume
echo -e "\033[1;34m[INFO]\033[0m Checking and extending LVM partition..."
LVM_PART=$(lsblk -o NAME,MOUNTPOINT | grep '/$' | awk '{print $1}')
if [ -n "$LVM_PART" ]; then
    VG_NAME=$(vgdisplay | grep 'VG Name' | awk '{print $3}')
    FREE_EXTENTS=$(vgdisplay $VG_NAME | grep 'Free  PE' | awk '{print $5}')
    if [ "$FREE_EXTENTS" -gt 0 ]; then
        lvextend -l +100%FREE /dev/$VG_NAME/root && resize2fs /dev/$VG_NAME/root
    else
        echo "No free space available to extend LVM."
    fi
else
    echo "No LVM partition found or already extended."
fi

# Prompt for QEMU Guest Agent
whiptail --title "QEMU Guest Agent" --yesno "Install QEMU Guest Agent?" 7 60
if [[ $? -eq 0 ]]; then
    echo -e "\033[1;34m[INFO]\033[0m Installing QEMU Guest Agent...${RESET}"
    apt install -y qemu-guest-agent && {
        systemctl enable --now qemu-guest-agent && {
            echo -e "${GREEN}✔ QEMU Guest Agent service enabled and started.${RESET}"
        } || {
            echo -e "${RED}Failed to enable/start QEMU Guest Agent service.${RESET}"
        }
    } || {
        echo -e "${RED}Failed to install QEMU Guest Agent.${RESET}"
    }
fi

# Prompt for Prometheus Node Exporter
whiptail --title "Prometheus Node Exporter" --yesno "Install Prometheus Node Exporter?" 7 60
if [[ $? -eq 0 ]]; then
    echo -e "\033[1;34m[INFO]\033[0m Installing Prometheus Node Exporter...${RESET}"
    apt install -y prometheus-node-exporter && {
        systemctl enable --now prometheus-node-exporter && {
            echo -e "${GREEN}✔ Prometheus Node Exporter service enabled and started.${RESET}"
        } || {
            echo -e "${RED}Failed to enable/start Prometheus Node Exporter service.${RESET}"
        }
    } || {
        echo -e "${RED}Failed to install Prometheus Node Exporter.${RESET}"
    }
fi

# Shell Setup
echo -e "\033[1;34m[INFO]\033[0m Installing Fish shell and Fisher...${RESET}"
apt install -y fish || echo -e "${RED}Failed to install Fish shell.${RESET}"
fish -c "curl -sL https://git.io/fisher | source && fisher install jorgebucaran/fisher"
fish -c "fisher install IlanCosman/tide && tide configure"

# After Tide is configured for root, prompt user to select users to install Tide and Fisher
echo -e "\033[1;33mSelect users to install Tide and Fisher for:\033[0m${RESET}"

# Get a list of system users
users=$(getent passwd | grep -vE 'nologin|false|root' | cut -d: -f1)

# Display user selection prompt
selected_users=$(whiptail --title "User Selection" --checklist \
    "Select users to install Tide and Fisher" 15 50 8 \
    $(for user in $users; do echo "$user" "$user" off; done) 3>&1 1>&2 2>&3)

# Remove extra quotes from the selected users (whiptail returns them with quotes)
selected_users=$(echo "$selected_users" | tr -d '"' | tr -s ' ')

# Install Tide and Fisher for selected users
for user in $selected_users; do
    echo -e "\033[1;34m[INFO]\033[0m Copying Fish configuration to $user...${RESET}"

    # Ensure the user's .config/fish directory exists
    mkdir -p "/home/$user/.config/fish"

    # Copy the root Fish config to the user's Fish directory
    cp -r /root/.config/fish/* "/home/$user/.config/fish/"

    # Fix permissions for the user's Fish config directory
    chown -R "$user:$user" "/home/$user/.config/fish"
done

# Prompt for Fish as the default shell
shell_choice=$(whiptail --menu "Set Fish shell as default for users" 15 60 3 \
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
    selected_users=$(whiptail --title "Select Users" --checklist "Select users to set Fish as default shell" 15 60 8 \
    $(for user in $users; do echo "$user" "$user" off; done) 3>&1 1>&2 2>&3)
    clear

    # Clean up the selected users
    selected_users=$(echo "$selected_users" | tr -d '"' | tr -s ' ')

    for user in $selected_users; do
        chsh -s /usr/bin/fish "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
    done
fi

# Tool Installation
echo -e "\033[1;34m[INFO]\033[0m Installing tools using Nala...${RESET}"
apt install -y nala && {
    nala install -y lsd ranger gdu bat duf || echo -e "${RED}Failed to install some tools.${RESET}"
} || echo -e "${RED}Failed to install Nala.${RESET}"

# Git Install for Functions
echo -e "\033[1;34m[INFO]\033[0m Installing Git..."
nala install git -y

# Custom Fish Functions Installation
whiptail --title "Custom Fish Functions" --yesno "Install custom Fish functions?" 7 60
if [[ $? -eq 0 ]]; then
    echo -e "\033[1;34m[INFO]\033[0m Cloning custom Fish functions from GitHub...${RESET}"
    
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
        echo -e "\033[1;34m[INFO]\033[0m Installing Fish functions system-wide...${RESET}"
        
        # Move the functions to the system-wide Fish functions directory
        mkdir -p /etc/fish/functions
        cp -r "$fish_functions_dir"/* /etc/fish/functions || {
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
    user_choice=$(whiptail --menu "Install Fish functions for" 15 60 3 \
        1 "All users" \
        2 "Specific users" \
        3 "Skip" \
        3>&1 1>&2 2>&3)
    clear

    if [[ $user_choice == "1" ]]; then
        echo -e "${GREEN}Functions are already available system-wide in /etc/fish/functions${RESET}"
    elif [[ $user_choice == "2" ]]; then
        users=$(getent passwd | cut -d: -f1)
        selected_users=$(whiptail --title "Select Users" --checklist "Select users to install functions" 15 60 8 \
        $(for user in $users; do echo "$user" "$user" off; done) 3>&1 1>&2 2>&3)
        clear

        # Clean up the selected users
        selected_users=$(echo "$selected_users" | tr -d '"' | tr -s ' ')

        for user in $selected_users; do
            user_home="/home/$user"
            mkdir -p "$user_home/.config/fish/functions"
            cp -r /etc/fish/functions* "$user_home/.config/fish/functions/"
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
