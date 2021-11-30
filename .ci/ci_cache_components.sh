#!/bin/bash
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# This script help us to build the
# cache of several kata components like
# qemu, kernel and images with the
# main purpose that being to be used at
# the CI to reduce the execution time

set -o errexit
set -o pipefail
set -o errtrace

cidir=$(dirname "$0")
source "${cidir}/../lib/common.bash"
source "${cidir}/lib.sh"

script_name=${0##*/}
WORKSPACE=${WORKSPACE:-$(pwd)}
kata_dir="/usr/share/kata-containers"
tests_repo="${tests_repo:-github.com/kata-containers/tests}"
tests_repo_dir="${GOPATH}/src/${tests_repo}"

# This builds qemu by specifying the qemu version from the
# runtime versions file and the qemu tar file name
cache_qemu_artifacts() {
	pushd "${tests_repo_dir}"
	local current_qemu_version=$(get_version "assets.hypervisor.qemu.version")
	popd
	local qemu_tar="kata-static-qemu.tar.gz"
	create_cache_asset "$qemu_tar" "${current_qemu_version}"
}

# This builds qemu experimental
cache_qemu_experimental_artifacts() {
	pushd "${tests_repo_dir}"
	local current_qemu_experimental_tag=$(get_version "assets.hypervisor.qemu-experimental.version")
	popd
	local qemu_experimental_tar="kata-static-qemu-experimental.tar.gz"
	create_cache_asset "$qemu_experimental_tar" "${current_qemu_experimental_tag}"
}

# This builds the kernel by specifying the kernel version from
# /usr/share/kata-containers and the kernel version
cache_kernel_artifacts() {
	for k in "${kata_dir}"/*.container; do
		echo "Adding ${k}"
		local real_path=$(readlink -f "${k}")
		#Get version from binary (format: vmlinu{z|x}-4.19.24-25)
		local kernel_binary=$(basename "${real_path}")
		local current_kernel_version=$(echo "${kernel_binary}" | cut -d- -f2-)
		create_cache_asset "${kernel_binary}" "${current_kernel_version}"
	done
}

# This builds cloud hypervisor
cache_cloud_hypervisor() {
	local cloud_hypervisor_binary="cloud-hypervisor"
	local cloud_hypervisor_binary_path="${GOPATH}/src/github.com/cloud-hypervisor/cloud-hypervisor"
	local current_cloud_hypervisor_version=$(get_version "assets.hypervisor.cloud_hypervisor.version")
	cp "${cloud_hypervisor_binary_path}/${cloud_hypervisor_binary}" .
	create_cache_asset "${cloud_hypervisor_binary}" "${current_cloud_hypervisor_version}"
}

# This builds the image by specifying the image version from
# /usr/share/kata-containers and the image name
cache_image_artifacts() {
	local image_name="image"
	local image_path="${kata_dir}/kata-containers.img"
	local path=$(readlink -f "${image_path}")
	local image_version=$(echo $(basename "${path}"))
	create_cache_asset "${image_name}" "${image_version}"
	create_image_tar "${image_name}"
}

# This builds the initrd image by specifying the image initrd version
# from /usr/share/kata-containers and the image initrd name
cache_image_initrd_artifacts() {
	local image_name="initrd"
	local image_path="${kata_dir}/kata-containers-initrd.img"
	local path=$(readlink -f "${image_path}")
	local image_version=$(echo $(basename "${path}"))
	create_cache_asset "${image_name}" "${image_version}"
	create_image_tar "${image_name}"
}

# This function receives as an argument if it is an image or an image initrd
create_image_tar(){
	local image_name="$1"
	local getinfo=$(cat latest-"${image_name}")
	tar -cJf "${getinfo}.tar.xz" "${getinfo}"
	sha256sum "${getinfo}.tar.xz" > "${image_name}-tarball.sha256sum"
	sha256sum -c "${image_name}-tarball.sha256sum"
	rm "${getinfo}"
}

# This function receives as arguments the component name (qemu, kernel, etc)
# as well as the version
create_cache_asset() {
	local component_name="$1"
	local component_version="$2"
	local check_image=$(echo "${component_version}" | grep kata || true)
	local check_cloud_hypervisor=$(echo "${component_version}" | grep cloud || true)
	local check_qemu=$(echo "${component_name}" | grep qemu || true)
	local check_kernel=$(echo "${component_name}" | grep -E '\<vmlinu[xz]\>' || true)
	local check_initrd=$(echo "${component_name}" | grep initrd || true)

	# Verify which kind of image we are using (initrd or not)
	if [ ! -z "${check_image}" ]; then
		if [ ! -z "${check_initrd}" ]; then
			image_path="${kata_dir}/kata-containers-initrd.img"
			image_name="initrd"
		else
			image_path="${kata_dir}/kata-containers.img"
			image_name="image"
		fi
		path=$(readlink -f "${image_path}")
		echo $(basename "${path}") > "latest-${image_name}"
		sudo cp "${path}" "${kata_dir}/osbuilder-${image_name}.yaml"  .
	elif [ ! -z "${check_qemu}" ]; then
		# The latest file is compounded of the QEMU version and SHA-256
		# calculated from all files and scripts used to its build.
		qemu_sha=$(calc_qemu_files_sha256sum)
		[ -n "$qemu_sha" ] || \
			die "Failed to calculate a SHA-256 for QEMU"
		echo "${component_version} ${qemu_sha}" > "latest"
	else
		echo "${component_version}" >  "latest"
	fi

	# In the case of qemu we have the tar at a specific location
	if [ ! -z "${check_qemu}" ]; then
		cp -a "${KATA_TESTS_CACHEDIR}/${component_name}" .
	fi

	# In the case of the kernel we have it in the kata dir
	if [ ! -z "${check_kernel}" ]; then
		cp "${kata_dir}/${component_name}" .
	fi

	sudo chown -R "${USER}:${USER}" .

	if [ ! -z "${check_image}" ]; then
		sha256sum "$(cat latest-${image_name})" > "sha256sum-${image_name}"
        	sha256sum -c "sha256sum-${image_name}"
	elif [ ! -z "${check_kernel}" ]; then
		sha256sum "${component_name}" >> "sha256sum-kernel"
		cat sha256sum-kernel
	else
		sha256sum "${component_name}" > "sha256sum-${component_name}"
		cat "sha256sum-${component_name}"
	fi
}

usage() {
cat <<EOF
Usage: $script_name [options]
Description: This script builds the cache of several Kata components.
Options:

-a      Run qemu experimental cache
-c      Run cloud hypervisor cache
-h      Shows help
-i      Run image cache
-k      Run kernel cache
-q      Run qemu cache
-r      Run image initrd cache

EOF
}

main() {
	local OPTIND
	while getopts "achiknqr" opt; do
		case "$opt" in
		a)
			build_qemu_experimental="true"
			;;
		c)
			build_cloud_hypervisor="true"
			;;
		h)
			usage
			exit 0;
			;;
		i)
			build_image="true"
			;;
		k)
			build_kernel="true"
 			;;
		q)
			build_qemu="true"
			;;
		r)
			build_image_initrd="true"
			;;
		esac
        done
        shift $((OPTIND-1))

	[[ -z "$build_kernel" ]] && \
	[[ -z "$build_qemu" ]] && \
	[[ -z "$build_qemu_experimental" ]] && \
	[[ -z "$build_cloud_hypervisor" ]] && \
	[[ -z "$build_image" ]] && \
	[[ -z "$build_image_initrd" ]] && \
		usage && die "Must choose at least one option"

        mkdir -p "${WORKSPACE}/artifacts"
        pushd "${WORKSPACE}/artifacts"
        echo "artifacts:"

	[ "$build_kernel" == "true" ] && cache_kernel_artifacts

	[ "$build_cloud_hypervisor" == "true" ] && cache_cloud_hypervisor

	[ "$build_qemu" == "true" ] && cache_qemu_artifacts

	[ "$build_qemu_experimental" == "true" ] && cache_qemu_experimental_artifacts

	[ "$build_image" == "true" ] && cache_image_artifacts

	[ "$build_image_initrd" == "true" ] && cache_image_initrd_artifacts

	ls -la "${WORKSPACE}/artifacts/"
	popd

	#The script is running in a VM as part of a CI Job, the artifacts will be
	#collected by the CI master node, sync to make sure any data is updated.
	sync
}

main "$@"
