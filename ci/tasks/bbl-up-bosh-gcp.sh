#!/bin/bash -ex

# BBL does not support ops files, so we write an override file for bbl to use. We attempt
# to assert the format of the script (now we have two problems) is as expected so our
# patching works.
assert_bbl_script_format() {
  local file="$1" verb="$2"
  local re='\A#!/bin/sh\n\S+ '"${verb}"'-env \\\n(?:[^\n]*\\\n)+[^\n]*[^\\\n]\n\z'

  grep -Pzq -- "${re}" "${file}" || {
    echo "FATAL: ${file} is not in the format this task knows how to patch."
    echo "       Did bbl's formatScript() (bosh/executor.go) chang?"
    echo "       (from: write_director_overrides in ci/tasks/bbl-up-bosh-gcp.sh)"
    echo "--- ${file} ---"
    cat "${file}"
    exit 1
  }
}

write_director_overrides() {
  local extra_ops=""
  local f verb
  for f in ${DIRECTOR_OPS_FILES}; do
    extra_ops="${extra_ops} -o  \${BBL_STATE_DIR}/bosh-deployment/${f}"
  done

  # create and delete must stay in lockstep — bbl generates them together, and
  # bbl-down-bosh-gcp.sh consumes the delete override out of the bbl-state output.
  for verb in create delete; do
    [ -f "${verb}-director.sh" ] || { echo "FATAL: bbl plan did not write ${verb}-director.sh"; exit 1; }
    assert_bbl_script_format "${verb}-director.sh" "${verb}"
    {
      sed '$ s/$/ \\/' "${verb}-director.sh"
      printf ' %s\n' "${extra_ops}"
    } > "${verb}-director-override.sh"
    chmod +x "${verb}-director-override.sh"
  done
}

bbl_up() {
  bbl plan
  rm -rf bosh-deployment
  cp -rfp "${bosh_deployment}" .

  if [ -n "${DIRECTOR_OPS_FILES:-}" ]; then
    write_director_overrides
  fi

  bbl --debug up
}

bosh_deployment="$PWD/bosh-deployment"

pushd "${PWD}/bbl-state"
  bbl_up
popd
