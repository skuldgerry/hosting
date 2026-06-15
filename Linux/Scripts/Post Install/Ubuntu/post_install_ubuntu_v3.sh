#!/bin/bash

# Colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# Safer shell options
# Do not use `set -e` here: whiptail returns non-zero for normal choices like No/Cancel,
# and install steps below already handle failures explicitly with if/else blocks.
set -uo pipefail
trap 'echo -e "${RED}An unexpected error occurred on line $LINENO. Exiting.${RESET}"; exit 1' ERR

# Install-state flags. Keep these initialized so set -u cannot fail in the summary.
install_qemu=0
install_prometheus=0
install_functions=0
install_tools=0
install_fish=0

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

# Return regular interactive users only
get_regular_users() {
  awk -F: '$3 >= 1000 && $1 != "nobody" && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd
}

# Return users eligible for shell changes, including root plus regular interactive users.
get_shell_users() {
  { echo "root"; get_regular_users; } | awk 'NF && !seen[$0]++'
}

# Run a whiptail checklist safely. Prints selected items without quotes, or nothing on Cancel/no selection.
# Optional third argument:
#   0/default = regular interactive users only
#   1         = include root as an option
select_users_checklist() {
  local title="$1"
  local message="$2"
  local include_root="${3:-0}"
  local users
  local selected

  if [[ "$include_root" -eq 1 ]]; then
    users=$(get_shell_users)
  else
    users=$(get_regular_users)
  fi

  if [[ -z "$users" ]]; then
    echo ""
    return 0
  fi

  selected=$(whiptail --title "$title" --checklist "$message" 15 60 8 \
    $(for user in $users; do echo "$user" "$user" off; done) \
    3>&1 1>&2 2>&3) || selected=""

  echo "$selected" | tr -d '"' | tr -s ' '
}

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root. Exiting.${RESET}"
    exit 1
fi

header_info

# Basic Linux Setup
echo -e "${BLUE}[INFO]${RESET} Updating system..."
apt update && apt install -y whiptail curl ca-certificates git && apt upgrade -y && apt dist-upgrade -y || {
    echo -e "${RED}System update failed. Exiting.${RESET}"
    exit 1
}

# Extend LVM root volume to use free VG space, if applicable
echo -e "${BLUE}[INFO]${RESET} Checking and extending LVM root volume..."
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_SOURCE" == /dev/mapper/* || "$ROOT_SOURCE" == /dev/*/* ]]; then
    if lvs "$ROOT_SOURCE" &>/dev/null; then
        VG_NAME=$(lvs --noheadings -o vg_name "$ROOT_SOURCE" | xargs)
        FREE_EXTENTS=$(vgs --noheadings -o vg_free_count "$VG_NAME" | xargs)
        if [[ "$FREE_EXTENTS" =~ ^[0-9]+$ && "$FREE_EXTENTS" -gt 0 ]]; then
            lvextend -r -l +100%FREE "$ROOT_SOURCE"
        else
            echo "No free space available to extend LVM."
        fi
    else
        echo "Root filesystem is not an LVM logical volume."
    fi
else
    echo "Root filesystem is not on LVM."
fi

# Prompt for QEMU Guest Agent
if whiptail --title "QEMU Guest Agent" --yesno "Install QEMU Guest Agent?" 7 60; then
    echo -e "${BLUE}[INFO]${RESET} Installing QEMU Guest Agent..."
    if apt install -y qemu-guest-agent; then
        if systemctl enable --now qemu-guest-agent; then
            echo -e "${GREEN}✔ QEMU Guest Agent service enabled and started.${RESET}"
            install_qemu=1
        else
            echo -e "${RED}Failed to enable/start QEMU Guest Agent service.${RESET}"
        fi
    else
        echo -e "${RED}Failed to install QEMU Guest Agent.${RESET}"
    fi
else
    echo -e "${CYAN}Skipping QEMU Guest Agent installation.${RESET}"
fi

# Prompt for Prometheus Node Exporter
if whiptail --title "Prometheus Node Exporter" --yesno "Install Prometheus Node Exporter?" 7 60; then
    echo -e "${BLUE}[INFO]${RESET} Installing Prometheus Node Exporter..."
    if apt install -y prometheus-node-exporter; then
        if systemctl enable --now prometheus-node-exporter; then
            echo -e "${GREEN}✔ Prometheus Node Exporter service enabled and started.${RESET}"
            install_prometheus=1
        else
            echo -e "${RED}Failed to enable/start Prometheus Node Exporter service.${RESET}"
        fi
    else
        echo -e "${RED}Failed to install Prometheus Node Exporter.${RESET}"
    fi
else
    echo -e "${CYAN}Skipping Prometheus Node Exporter installation.${RESET}"
fi

# Shell Setup
echo -e "${BLUE}[INFO]${RESET} Installing Fish shell and Fisher..."
if apt install -y fish; then
    install_fish=1
    FISH_PATH=$(command -v fish)

    if ! grep -qxF "$FISH_PATH" /etc/shells; then
        echo "$FISH_PATH" >> /etc/shells
    fi

    if fish -c "curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher"; then
        fish -c "fisher install IlanCosman/tide" || echo -e "${RED}Failed to install Tide for root.${RESET}"
    else
        echo -e "${RED}Failed to install Fisher for root.${RESET}"
    fi

    # Optional: run `tide configure` interactively after the script if you want to customise the prompt.

    # After Tide is configured for root, prompt user to select users to install Tide and Fisher
    echo -e "${YELLOW}Select users to install Tide and Fisher for:${RESET}"
    selected_users=$(select_users_checklist "User Selection" "Select users to install Tide and Fisher")
    clear

    # Install Tide and Fisher for selected users
    for user in $selected_users; do
        user_home=$(getent passwd "$user" | cut -d: -f6)
        if [[ -z "$user_home" || ! -d "$user_home" ]]; then
            echo -e "${RED}Skipping $user: home directory not found.${RESET}"
            continue
        fi

        echo -e "${BLUE}[INFO]${RESET} Copying Fish configuration to $user..."
        mkdir -p "$user_home/.config/fish"

        if compgen -G "/root/.config/fish/*" > /dev/null; then
            cp -r /root/.config/fish/* "$user_home/.config/fish/"
            chown -R "$user:$user" "$user_home/.config/fish" || echo -e "${RED}Failed to set permissions for $user.${RESET}"
        else
            echo -e "${CYAN}No root Fish configuration found to copy.${RESET}"
        fi
    done

    # Prompt for Fish as the default shell
    shell_choice=$(whiptail --menu "Set Fish shell as default shell" 15 60 3 \
        1 "All users, including root" \
        2 "Select users" \
        3 "Skip" \
        3>&1 1>&2 2>&3) || shell_choice="3"
    clear

    if [[ "$shell_choice" == "1" ]]; then
        while read -r user; do
            chsh -s "$FISH_PATH" "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
        done < <(get_shell_users)
    elif [[ "$shell_choice" == "2" ]]; then
        selected_users=$(select_users_checklist "Select Users" "Select users to set Fish as default shell" 1)
        clear

        for user in $selected_users; do
            chsh -s "$FISH_PATH" "$user" || echo -e "${RED}Failed to set Fish for $user.${RESET}"
        done
    fi
else
    echo -e "${RED}Failed to install Fish shell. Skipping Fish configuration.${RESET}"
fi

# Tool Installation
echo -e "${BLUE}[INFO]${RESET} Installing tools using Nala..."
if apt install -y nala; then
    if nala install -y lsd ranger gdu bat duf; then
        install_tools=1
        echo -e "${GREEN}✔ Tools installed successfully.${RESET}"
    else
        echo -e "${RED}Failed to install some tools.${RESET}"
    fi
else
    echo -e "${RED}Failed to install Nala.${RESET}"
fi

# Git Install for Functions. Git is already installed during the initial setup, but keep this as a safe re-check.
echo -e "${BLUE}[INFO]${RESET} Ensuring Git is installed..."
if command -v nala &>/dev/null; then
    nala install git -y || apt install -y git || echo -e "${RED}Failed to install Git.${RESET}"
else
    apt install -y git || echo -e "${RED}Failed to install Git.${RESET}"
fi

# Custom Fish Functions Installation
if [[ "$install_fish" -eq 1 ]] && whiptail --title "Custom Fish Functions" --yesno "Install custom Fish functions?" 7 60; then
    echo -e "${BLUE}[INFO]${RESET} Cloning custom Fish functions from GitHub..."

    temp_dir=$(mktemp -d)

    if git clone --depth 1 --single-branch --branch main \
        "https://github.com/skuldgerry/hosting.git" "$temp_dir"; then

        fish_functions_dir="$temp_dir/Linux/Fish_Functions"

        if [[ -d "$fish_functions_dir" ]]; then
            echo -e "${BLUE}[INFO]${RESET} Installing Fish functions system-wide..."
            mkdir -p /etc/fish/functions

            if cp -r "$fish_functions_dir"/* /etc/fish/functions/; then
                install_functions=1
            else
                echo -e "${RED}Failed to copy Fish functions to system-wide directory.${RESET}"
            fi
        else
            echo -e "${RED}Fish functions directory not found.${RESET}"
        fi

        if [[ "$install_functions" -eq 1 ]]; then
            user_choice=$(whiptail --menu "Install Fish functions for" 15 60 3 \
                1 "All users" \
                2 "Specific users" \
                3 "Skip" \
                3>&1 1>&2 2>&3) || user_choice="3"
            clear

            if [[ "$user_choice" == "1" ]]; then
                echo -e "${GREEN}Functions are already available system-wide in /etc/fish/functions${RESET}"
            elif [[ "$user_choice" == "2" ]]; then
                selected_users=$(select_users_checklist "Select Users" "Select users to install functions")
                clear

                for user in $selected_users; do
                    user_home=$(getent passwd "$user" | cut -d: -f6)
                    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
                        echo -e "${RED}Skipping $user: home directory not found.${RESET}"
                        continue
                    fi

                    mkdir -p "$user_home/.config/fish/functions"
                    cp -r /etc/fish/functions/* "$user_home/.config/fish/functions/"
                    chown -R "$user:$user" "$user_home/.config/fish" || echo -e "${RED}Failed to set permissions for $user.${RESET}"
                done
            fi
        fi
    else
        echo -e "${RED}Failed to clone Fish functions from GitHub.${RESET}"
    fi

    rm -rf "$temp_dir"
else
    echo -e "${CYAN}Skipping Fish functions installation.${RESET}"
fi

# Final Summary
echo -e "\n${CYAN}Summary of Actions:${RESET}"
echo -e "${GREEN}✔ System updated${RESET}"
[[ "$install_qemu" -eq 1 ]] && echo -e "${GREEN}✔ QEMU Guest Agent installed${RESET}" || echo -e "${CYAN}○ QEMU Guest Agent skipped${RESET}"
[[ "$install_prometheus" -eq 1 ]] && echo -e "${GREEN}✔ Prometheus Node Exporter installed${RESET}" || echo -e "${CYAN}○ Prometheus Node Exporter skipped${RESET}"
[[ "$install_fish" -eq 1 ]] && echo -e "${GREEN}✔ Fish shell installed/configured where selected${RESET}" || echo -e "${CYAN}○ Fish shell skipped or failed${RESET}"
[[ "$install_functions" -eq 1 ]] && echo -e "${GREEN}✔ Custom Fish functions installed${RESET}" || echo -e "${CYAN}○ Custom Fish functions skipped${RESET}"
[[ "$install_tools" -eq 1 ]] && echo -e "${GREEN}✔ Tools installed: nala, lsd, ranger, gdu, bat, duf${RESET}" || echo -e "${CYAN}○ Some tools were skipped or failed${RESET}"
echo -e "\n${GREEN}Post-install setup completed successfully!${RESET}"
