#!/bin/bash

# Colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# Safer shell options
# Do not use `set -e` or a global ERR trap here: whiptail returns non-zero for normal
# choices like No/Cancel/Esc, and install steps below already handle failures explicitly.
set -uo pipefail

# Graceful exit helper. Ctrl+C / SIGTERM should actually stop the script, while normal
# whiptail No/Cancel handling is managed per prompt below.
exit_script() {
  local message="${1:-User requested exit.}"
  echo -e "\n${YELLOW}${message}${RESET}"
  echo -e "${CYAN}Post-install script stopped before completion.${RESET}"
  exit 130
}

trap 'exit_script "Interrupted by user."' INT TERM

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

# Ask whether a cancelled dialog should exit the whole script.
# No = cancel/skip only the current prompt and continue.
confirm_exit_after_cancel() {
  local context="$1"

  if whiptail --title "${context} cancelled" \
    --yesno "You cancelled: ${context}\n\nExit the post-install script now?\n\nChoose No to skip this prompt and continue." 11 70; then
    exit_script "User chose to exit from: ${context}."
  fi

  return 0
}

# Uniform yes/no prompt wrapper.
# Return codes:
#   0 = Yes
#   1 = No, Cancel, or Esc after choosing to continue
ask_yes_no() {
  local title="$1"
  local message="$2"
  local status

  whiptail --title "$title" --yesno "$message" 8 70
  status=$?

  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    255)
      confirm_exit_after_cancel "$title"
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Uniform menu wrapper. Prints the selected item. Returns non-zero if skipped/cancelled.
select_menu() {
  local title="$1"
  local message="$2"
  shift 2
  local choice
  local status

  choice=$(whiptail --title "$title" --menu "$message" 16 70 6 "$@" 3>&1 1>&2 2>&3)
  status=$?

  case "$status" in
    0)
      echo "$choice"
      return 0
      ;;
    1|255)
      confirm_exit_after_cancel "$title"
      return 1
      ;;
    *)
      return 1
      ;;
  esac
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
  local status

  if [[ "$include_root" -eq 1 ]]; then
    users=$(get_shell_users)
  else
    users=$(get_regular_users)
  fi

  if [[ -z "$users" ]]; then
    echo ""
    return 0
  fi

  selected=$(whiptail --title "$title" --checklist "$message" 16 70 8 \
    $(for user in $users; do echo "$user" "$user" off; done) \
    3>&1 1>&2 2>&3)
  status=$?

  case "$status" in
    0)
      echo "$selected" | tr -d '"' | tr -s ' '
      return 0
      ;;
    1|255)
      confirm_exit_after_cancel "$title"
      echo ""
      return 1
      ;;
    *)
      echo ""
      return 1
      ;;
  esac
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
if ask_yes_no "QEMU Guest Agent" "Install QEMU Guest Agent?"; then
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
if ask_yes_no "Prometheus Node Exporter" "Install Prometheus Node Exporter?"; then
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

    # Prompt for Tide/Fisher using the same pattern as the default-shell prompt.
    tide_choice=$(select_menu "Install Tide and Fisher" "Install Tide and Fisher for:" \
        1 "All users, including root" \
        2 "Select users" \
        3 "Skip") || tide_choice="3"
    clear

    selected_users=""
    if [[ "$tide_choice" == "1" ]]; then
        selected_users=$(get_shell_users)
    elif [[ "$tide_choice" == "2" ]]; then
        selected_users=$(select_users_checklist "Select Users" "Select users to install Tide and Fisher" 1) || selected_users=""
        clear
    fi

    # Copy the root Fish configuration, including Fisher/Tide files, to selected non-root users.
    for user in $selected_users; do
        if [[ "$user" == "root" ]]; then
            continue
        fi

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
    shell_choice=$(select_menu "Set Fish shell as default shell" "Set Fish shell as default shell for:" \
        1 "All users, including root" \
        2 "Select users" \
        3 "Skip") || shell_choice="3"
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
summary_text=$(cat <<EOF
Summary of Actions

✔ System updated
$([[ "$install_qemu" -eq 1 ]] && echo "✔ QEMU Guest Agent installed" || echo "○ QEMU Guest Agent skipped")
$([[ "$install_prometheus" -eq 1 ]] && echo "✔ Prometheus Node Exporter installed" || echo "○ Prometheus Node Exporter skipped")
$([[ "$install_fish" -eq 1 ]] && echo "✔ Fish shell installed/configured where selected" || echo "○ Fish shell skipped or failed")
$([[ "$install_functions" -eq 1 ]] && echo "✔ Custom Fish functions installed" || echo "○ Custom Fish functions skipped")
$([[ "$install_tools" -eq 1 ]] && echo "✔ Tools installed: nala, lsd, ranger, gdu, bat, duf" || echo "○ Some tools were skipped or failed")

Post-install setup completed successfully!
EOF
)

echo -e "\n${CYAN}Summary of Actions:${RESET}"
echo "$summary_text"

if command -v whiptail &>/dev/null; then
    whiptail --title "Post-install Summary" --msgbox "$summary_text" 20 78 || true
fi

if [[ "$install_fish" -eq 1 ]]; then
    if ask_yes_no "Launch Fish" "Switch to Fish now?\n\nTip: if Tide was installed, type:\n\n  tide configure\n\nto customise your prompt."; then
        echo -e "${GREEN}Switching to Fish.${RESET}"
        echo -e "${CYAN}Tip: type 'tide configure' to customise Tide.${RESET}"
        exec "$FISH_PATH"
    fi
fi
