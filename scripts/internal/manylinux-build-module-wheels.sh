#!/usr/bin/env bash

# Run this script inside a dockcross container to build Python wheels for an ITK module.
#
# Versions can be restricted by passing them in as arguments to the script.
# For example,
#
#   /tmp/dockcross-manylinux-x64 manylinux-build-module-wheels.sh cp39
#
# Shared library dependencies can be included in the wheel by mounting them to /usr/lib64 or /usr/local/lib64 
# before running this script.
# 
# For example,
#
#   DOCKER_ARGS="-v /path/to/lib.so:/usr/local/lib64/lib.so"
#   /tmp/dockcross-manylinux-x64 -a "$DOCKER_ARGS" manylinux-build-module-wheels.sh
#
# The specialized manylinux container version should be set prior to running this script.
# See https://github.com/dockcross/dockcross for available versions and tags.
#
# For example, `docker run -e <var>` can be used to set an environment variable when launching a container:
#
#   export MANYLINUX_VERSION=2014
#   docker run --rm dockcross/manylinux${MANYLINUX_VERSION}-x64:${IMAGE_TAG} > /tmp/dockcross-manylinux-x64
#   chmod u+x /tmp/dockcross-manylinux-x64
#   /tmp/dockcross-manylinux-x64 -e MANYLINUX_VERSION manylinux-build-module-wheels.sh cp39
#

# -----------------------------------------------------------------------
# Script argument parsing
#
usage()
{
  echo "Usage:
  manylinux-build-module-wheels
    [ -h | --help ]           show usage
    [ -c | --cmake_options ]  space-separated string of CMake options to forward to the module (e.g. \"-DBUILD_TESTING=OFF\")
    [ -x | --exclude_libs ]   semicolon-separated library names to exclude when repairing wheel (e.g. \"libcuda.so\")
    [ python_version ]        build wheel for a specific python version. (e.g. cp39)"
  exit 2
}

PARSED_ARGS=$(getopt -a -n dockcross-manylinux-download-cache-and-build-module-wheels \
  -o hc:x: --long help,cmake_options:,exclude_libs: -- "$@")
eval set -- "$PARSED_ARGS"

while :
do
  case "$1" in
    -h | --help) usage; break ;;
    -c | --cmake_options) CMAKE_OPTIONS="$2" ; shift 2 ;;
    -x | --exclude_libs) EXCLUDE_LIBS="$2" ; shift 2 ;;
    --) shift; break ;;
    *) echo "Unexpected option: $1.";
       usage; break ;;
  esac
done

PYTHON_VERSION="$@"
# -----------------------------------------------------------------------

# -----------------------------------------------------------------------
# These variables are set in common script:
#
ARCH=""
PYBINARIES=""

script_dir=$(cd $(dirname $0) || exit 1; pwd)
source "${script_dir}/manylinux-build-common.sh"
# -----------------------------------------------------------------------

# Set up library paths in container so that shared libraries can be added to wheels
sudo ldconfig
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/work/oneTBB-prefix/lib:/usr/lib:/usr/lib64:/usr/local/lib:/usr/local/lib64

# Swig pre-built version from ITK build in ITKPythonPackage
SWIG_VERSION=4.0.2

# Compile wheels re-using standalone project and archive cache
for PYBIN in "${PYBINARIES[@]}"; do
    Python3_EXECUTABLE=${PYBIN}/python
    Python3_INCLUDE_DIR=$( find -L ${PYBIN}/../include/ -name Python.h -exec dirname {} \; )

    echo ""
    echo "Python3_EXECUTABLE:${Python3_EXECUTABLE}"
    echo "Python3_INCLUDE_DIR:${Python3_INCLUDE_DIR}"

    if [[ -e /work/requirements-dev.txt ]]; then
      ${PYBIN}/pip install --upgrade -r /work/requirements-dev.txt
    elif [[ -e /ITKPythonPackage/requirements-dev.txt ]]; then
      ${PYBIN}/pip install --upgrade -r /ITKPythonPackage/requirements-dev.txt
    fi
    version=$(basename $(dirname ${PYBIN}))
    # Remove "m" -- not present in Python 3.8 and later
    version=${version:0:9}
    itk_build_dir=/work/$(basename /ITKPythonPackage/ITK-${version}*-manylinux${MANYLINUX_VERSION}_${ARCH})
    ln -fs /ITKPythonPackage/ITK-${version}*-manylinux${MANYLINUX_VERSION}_${ARCH} $itk_build_dir
    if [[ ! -d ${itk_build_dir} ]]; then
      echo 'ITK build tree not available!' 1>&2
      exit 1
    fi
    itk_source_dir=/work/ITK-source/ITK
    ln -fs /ITKPythonPackage/ITK-source/ /work/ITK-source
    if [[ ! -d ${itk_source_dir} ]]; then
      echo 'ITK source tree not available!' 1>&2
      exit 1
    fi
    swig_args=""
    if [[ "${ARCH}" = "x64" ]]; then
      swig_args="-DITK_USE_SYSTEM_SWIG:BOOL=ON -DSWIG_VERSION:STRING=${SWIG_VERSION} -DSWIG_EXECUTABLE:FILEPATH=${itk_build_dir}/Wrapping/Generators/SwigInterface/swiglinux-${SWIG_VERSION}/bin/swig -DSWIG_DIR:FILEPATH=${itk_build_dir}/Wrapping/Generators/SwigInterface/swiglinux-${SWIG_VERSION}/share/swig/${SWIG_VERSION}"
    fi
    ${PYBIN}/python setup.py clean
    ${PYBIN}/python setup.py bdist_wheel --build-type Release -G Ninja -- \
      -DITK_DIR:PATH=${itk_build_dir} \
      -DWRAP_ITK_INSTALL_COMPONENT_IDENTIFIER:STRING=PythonWheel \
      -DCMAKE_CXX_COMPILER_TARGET:STRING=$(uname -m)-linux-gnu \
      -DCMAKE_INSTALL_LIBDIR:STRING=lib \
      -DBUILD_TESTING:BOOL=OFF \
      -DPython3_EXECUTABLE:FILEPATH=${Python3_EXECUTABLE} \
      -DPython3_INCLUDE_DIR:PATH=${Python3_INCLUDE_DIR} \
      ${swig_args} ${CMAKE_OPTIONS} \
    || exit 1
done

# Make sure auditwheel is installed for this python exe before importing
# it in auditwheel_whitelist_monkeypatch.py
sudo ${Python3_EXECUTABLE} -m pip install auditwheel
for whl in dist/*linux*$(uname -m).whl; do
  # Repair wheel using monkey patch to exclude shared libraries provided in whitelist
  ${Python3_EXECUTABLE} "${script_dir}/auditwheel_whitelist_monkeypatch.py" \
    repair ${whl} -w /work/dist/ --whitelist "${EXCLUDE_LIBS}"
  rm ${whl}
done

if compgen -G "dist/itk*-linux*.whl" > /dev/null; then
  for itk_wheel in dist/itk*-linux*.whl; do
    mv ${itk_wheel} ${itk_wheel/linux/manylinux${MANYLINUX_VERSION}}
  done
fi
