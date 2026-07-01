#!/bin/bash

# Fail on any error.
set -e

# Debug mode for diagnosing issues.
# Setup first before other operations.
debug="${2}"
test "${debug}" = "true" && set -x

# Include library.
script_dir="$(dirname -- "$(realpath -- "${0}")")"
source "${script_dir}/lib.sh"

# Directory that holds the cached packages.
cache_dir="${1}"

# Don't install recommended packages.
no_install_recommends="${3}"

# Don't upgrade existing packages.
no_upgrade="${4}"

# Repositories to add before installing packages.
add_repository="${5}"

# List of the packages to use.
input_packages="${@:6}"

if ! apt-fast --version > /dev/null 2>&1; then
  log "Installing apt-fast for optimized installs..."
  # Install apt-fast for optimized installs.
  /bin/bash -c "$(curl -sL https://raw.githubusercontent.com/ilikenwf/apt-fast/master/quick-install.sh)"
  log "done"

  log_empty_line
fi

# Add custom repositories if specified
if [ -n "${add_repository}" ]; then
  log "Adding custom repositories..."
  for repository in ${add_repository}; do
    log "- Adding repository: ${repository}"
    sudo apt-add-repository -y "${repository}"
  done
  log "done"
  log_empty_line
fi

log "Updating APT package list..."
update_apt_lists_if_stale

log_empty_line

packages="$(get_normalized_package_list "${input_packages}")"
package_count=$(wc -w <<< "${packages}")
log "Clean installing and caching ${package_count} package(s)."

log_empty_line

manifest_main=""
log_debug "Package list:"
for package in ${packages}; do
  manifest_main="${manifest_main}${package},"
  log_debug "- ${package}"
done
write_manifest "main" "${manifest_main}" "${cache_dir}/manifest_main.log"

log_empty_line

# Strictly contains the requested packages.
manifest_main=""
# Contains all packages including dependencies.
manifest_all=""

install_log_filepath="${cache_dir}/install.log"

declare -a apt_options
if test "${no_install_recommends}" = "true" ; then
  apt_options+=( "--no-install-recommends" )
fi
if test "${no_upgrade}" = "true" ; then
  apt_options+=( "--no-upgrade" )
fi

log "Clean installing ${package_count} packages..."
# Zero interaction while installing or upgrading the system via apt.
sudo DEBIAN_FRONTEND=noninteractive apt-fast --yes install ${apt_options[@]} ${packages} > "${install_log_filepath}"
log "done"
log "Installation log written to ${install_log_filepath}"

log_empty_line

installed_packages=$(get_installed_packages "${install_log_filepath}")
if [ "${debug}" == "true" ] ; then
  log "Installed package list:"
  for installed_package in ${installed_packages}; do
    # Reformat for human friendly reading.  
    log "- $(echo ${installed_package} | awk -F\= '{print $1" ("$2")"}')"
  done
fi

log_empty_line

installed_packages_count=$(wc -w <<< "${installed_packages}")
log "Caching ${installed_packages_count} installed packages..."
for installed_package in ${installed_packages}; do
  cache_filepath="${cache_dir}/${installed_package}.tar"

  # Sanity test in case APT enumerates duplicates.
  if test ! -f "${cache_filepath}"; then
    read package_name package_ver < <(get_package_name_ver "${installed_package}")
    log_debug "  * Caching ${package_name} to ${cache_filepath}..."

    # Get the entry in /var/lib/dpkg/status
    mkdir -p /var/tmp/dpkg-restore || :
    sed -n -r -e "/Package:\s+${package_name}$/,/^$/p" /var/lib/dpkg/status > /var/tmp/dpkg-restore/${package_name}.status
    
    # Pipe all package files (no folders), including symlinks, their targets, and installation control data to Tar.
    tar -cf "${cache_filepath}" -C / --verbatim-files-from --files-from <(
      { dpkg -L "${package_name}" && echo "/var/tmp/dpkg-restore/${package_name}.status" &&
        get_install_script_filepaths "/" "${package_name}" ; } |
      while IFS= read -r f; do
        if test -f "${f}" -o -L "${f}"; then
          get_tar_relpath "${f}"
          if [ -L "${f}" ]; then
            target="$(readlink -f "${f}")"
            if [ -f "${target}" ]; then
              get_tar_relpath "${target}"
            fi
          fi
        fi
      done
    )

    log_debug "    done (compressed size $(du -h "${cache_filepath}" | cut -f1))."
  fi

  # Comma delimited name:ver pairs in the all packages manifest.
  manifest_all="${manifest_all}${package_name}=${package_ver},"
done
log "done (total cache size $(du -h ${cache_dir} | tail -1 | awk '{print $1}'))"

log_empty_line

write_manifest "all" "${manifest_all}" "${cache_dir}/manifest_all.log"
