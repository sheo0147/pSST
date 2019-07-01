#!/bin/sh
##############################################################################
# certupdate.sh
#   Let's Encrypt free DV certificate updater.
#   Author: HEO SeonMeyong (seirios@seirios.org)
#   License: BSD 2 clause
##############################################################################

__VERSION="0.1"
__TAB=$'\t'

: ${__DBG:=0}					# Debug Information
: ${__TEST:=0}					# Dry Run
: ${__ACME:=1}					# Get or renew Certificate
: ${__DIST:=1}					# Distribute
: ${__FORCE:=0}					# Force update/distribute

: ${__DUSER:=""}				# Distribute username for ssh.
: ${__HOME:="${PWD}"}				# Certificate home directory.
: ${__WEBR:="${__HOME}/htdocs"}			# ACME WebRoot Directory.
: ${__CONF:="${__HOME}/certupdate.conf"}	# configuration file.
: ${__DOMF:="${__HOME}/domains.conf"}		# Domains configuration file.
: ${__CAI:="LE"}				# CA issure.
: ${__ACME_ACTION:="--issue"}			# ACME Action.

__LOG="/dev/null"
__CONF_TMP=""
__DOMF_TMP=""
__HOME_TMP=""

##### functions definition.
cu_debug() { # Debug output to stderr. ${1}:Messages / ${2}:Flag(Exit)
  echo "DBG:${1}" >&2
  echo "DBG:${1}" >> ${__LOG}
  [ -n "${2}" ] && exit 1
}

cu_usage() { # Usage Message. force exit.
  echo "${0} v.${__VERSION}"
  echo "Usage: ${0} -adfrtv -C [config file] -D [domain file] -H [home dir]"
  echo "	-a: not run acme process"
  echo "	-d: not distribute certificate file"
  echo "	-f: force run acme/distribute"
  echo "	-t: ACME issue Process running on TEST mode)"
  echo "	-r: renew certificate. (default issue)"
  echo "	-V: Verbose/DEBUG"
  echo "	-C [config file]: configuration file (Default: ./certupdate.conf)"
  echo "	-D [domain file]: domain definition file (Default: ./domains.conf)"
  echo "	-H [home dir]:    Cert file storages and work home (default: .)"
  echo "	-W [WebRoot dir]: ACME WebRoot Dir (default: ./htdocs)"
  exit 1
}

cu_count_arg() { # count argument
  echo ${#}
}

cu_sort_uniq_arg() { # sort and uniq the argument
  for i in $*; do
    echo ${i}
  done | sort | uniq | wc -l | sed "s/^[ ${__TAB}]*//"
}

##### Main #####

### Get options.

while getopts "adfrtVC:D:H:W:" __FLAG__; do
  case "${__FLAG__}" in
  a)	# not run ACME
    __ACME=0
  ;;
  d)	# not distrib certs
    __DIST=0
  ;;
  f)	# Force
    __FORCE=1
  ;;
  r)	# Dry-Run
    __ACME_ACTION="--renew"
  ;;
  t)	# Dry-Run
    __TEST=1
  ;;
  V)	# Verboce/Debug
    __DBG=1
    __LOG="`basename ${0}`.log"
    [ -f ${__LOG} ] && rm ${__LOG} && touch ${__LOG}
  ;;
  C)	# Config file
    __CONF_TMP=${OPTARG}
  ;;
  D)	# Domains file
    __DOMF_TMP=${OPTARG}
  ;;
  H)	# Home Directory
    __HOME_TMP=${OPTARG}
  ;;
  W)	# WebRoot Directory
    __WEBR_TMP=${OPTARG}
  ;;
  *)
    cu_usage
    exit 1
  ;;
  esac
done

[ "${__ACME}" -eq 0 -a "${__DIST}" -eq 0 ] && echo "done." && exit 0

if [ "${__DBG}" -ne 0 ]; then
  cu_debug "TEST    =${__TEST}"
  cu_debug "ACME    =${__ACME}"
  cu_debug "DIST    =${__DIST}"
  cu_debug "FORCE   =${__FORCE}"
fi

### Parse conf.

[ -n "${__HOME_TMP}" ] && __HOME="${__HOME_TMP%/}"
[ -n "${__HOME_TMP}" ] && __CONF="${__HOME}/certupdate.conf"
[ -n "${__CONF_TMP}" ] && __CONF="${__CONF_TMP}"
[ ! -f "${__CONF}" ] && echo "Error: ${__CONF} is not found" && cu_usage
. ${__CONF}
[ ${?} -ne 0 ] && echo "Error: Configuration file ${__CONF} is somthing wrong. check it." && exit 1

[ -n "${__HOME_TMP}" ] && __HOME=${__HOME_TMP%/} || __HOME=${PWD%/}
[ -n "${__DOMF_TMP}" ] && __DOMF="${__DOMF_TMP}"
[ -n "${__WEBR_TMP}" ] && __WEBR="${__WEBR_TMP}"
__WORK="${__HOME}/CERTS"

[ -f ${__WORK}/acme.sh.log ] && rm ${__WORK}/acme.sh.log

if [ "${__DBG}" -ne 0 ]; then
  cu_debug "CONF_TMP=${__CONF_TMP}"
  cu_debug "CONF    =${__CONF}"
  cu_debug "DOMF_TMP=${__DOMF_TMP}"
  cu_debug "DOMF    =${__DOMF}"
  cu_debug "HOME_TMP=${__HOME_TMP}"
  cu_debug "HOME    =${__HOME}"
  cu_debug "WEBR_TMP=${__WEBR_TMP}"
  cu_debug "WEBR    =${__WEBR}"
  cu_debug "WORK    =${__WORK}"
  cu_debug "USER   =${__DUSER}"
fi

[ ! -f "${__DOMF}" ] && echo "Error: ${__DOMF} is not found" && cu_usage
[ ! -d "${__HOME}" ] && echo "Error: ${__HOME} is not found" && cu_usage
[ ! -r "${__HOME}" -o ! -w "${__HOME}" -o ! -x "${__HOME}" ] \
	&& echo "Error: permission denid ${__HOME} " && exit 1

if [ ! -e "${__WEBR}" ]; then
  mkdir ${__WEBR}
  [ ${?} -ne 0 ] && echo "Error: Cannot make ${__WEBR} directory." && exit 1
  ln -s ${__WEBR} ${__WEBR}/.well-known
  ln -s ${__WEBR} ${__WEBR}/acme-challenge
  cat << __END__ > ${__WEBR}/index.html
<HTML>
<BODY>
</BODY>
<CENTER><H1> Not public </H1></CENTER>
<HR>
<P>
This page is not public. Bye!!
</P>
</HTML>
__END__
elif [ ! -d "${__WEBR}" ]; then
  echo "Error: ${__WEBR} is not directory." && exit 1
elif [ ! -r "${__WEBR}" -o ! -w "${__WEBR}" -o ! -x "${__WEBR}" ]; then
  echo "Error: permission denid ${__WEBR} " && exit 1
fi

if [ ! -e "${__WORK}" ]; then
  mkdir ${__WORK}
  [ ${?} -ne 0 ] && echo "Error: Cannot make ${__WORK} directory." && exit 1
elif [ ! -d "${__WORK}" ]; then
  echo "Error: ${__WORK} is not directory." && exit 1
elif [ ! -r "${__WORK}" -o ! -w "${__WORK}" -o ! -x "${__WORK}" ]; then
  echo "Error: permission denid ${__WORK} " && exit 1
fi

# XXX temporaly XXX
sudo service nginx restart > /dev/null 2>&1
# XXX temporaly XXX

### Parse domain.

while read __LINE__; do

  __UPD=0
  __DOM=`echo "${__LINE__}" | sed -e "s/^[ ${__TAB}]+//" -e "s/[#|].*$//" -e "s/[ ${__TAB}]*$//"`
  [ -z "${__DOM}" ] && continue

  echo "Get ${__DOM} Certificate from ${__CAI}"

  # Check SAN(Subject Alternative Name)
  __SAN__="";__SAN_O__=0;__SAN_C__=0
  if [ -e "${__HOME}/SAN/${__DOM}" ]; then
    [ "${__DBG}" -ne 0 ] && cu_debug "SAN found."
    while read i; do
      __i=`echo "${i}"   | sed -e "s/^[ ${__TAB}]+//" -e "s/[#].*$//" -e "s/[ ${__TAB}]*$//"`
      [ -z "${__i}" ] && continue
      __SAN__="${__SAN__} ${__i}"
    done < ${__HOME}/SAN/${__DOM}

    __SAN_O__=`cu_count_arg ${__SAN__}`
    __SAN_C__=`cu_sort_uniq_arg ${__SAN__}`

    if [ "${__DBG}" -ne 0 ]; then
      cu_debug "SAN_O=${__SAN_O__}."
      cu_debug "SAN_C=${__SAN_C__}."
      cu_debug "SAN=${__SAN__}."
    fi

    if [ "${__SAN_O__}" -ne "${__SAN_C__}" ]; then
      echo "Error: ${__DOM}: some SAN entry is duplicated. ${__DOM} is skipped."
    [ "${__DBG}" -ne 0 ] && cu_debug "Error: ${__DOM}: some SAN entry is duplicated. ${__DOM} is skipped."
      continue
    elif [ "${__SAN_O__}" -gt 100 ]; then
      echo "Error: ${__DOM}: SAN entry is more than 100. ${__DOM} is skipped."
      [ "${__DBG}" -ne 0 ] && cu_debug "Error: ${__DOM}: SAN entry is more than 100. ${__DOM} is skipped."
      continue
    fi
  fi

  [ -z "${__SAN__}" ] && __SAN__="${__DOM}"
  __SAN__="-d `echo ${__SAN__} | sed -e 's/^[[:space:]]//' -e 's/ / -d /g'`"
  [ "${__DBG}" -ne 0 ] && cu_debug "SAN=${__SAN__}."

  # issue or renew certs.
  if [ "${__ACME}" -ne 0 ]; then

    __ACME_OPTS__="${__ACME_ACTION} ${__SAN__} --home ${__WORK} --log ${__WORK}/acme.sh.log"
    __ACME_OPTS_WEB__="--webroot ${__WEBR}"
    __ACME_OPTS_CF__=""

    [ "${__FORCE}" -ne 0 ] && __ACME_OPTS_CF__="${__ACME_OPTS_CF__} -f"
    [ "${__TEST}" -ne 0 ]  && __ACME_OPTS_CF__="${__ACME_OPTS_CF__} --test"

    acme.sh ${__ACME_OPTS__} ${__ACME_OPTS_CF__} ${__ACME_OPTS_WEB__} 2>&1 > /dev/null
    case "${?}" in
    0)	# Issued certificate.
      echo "${__DOM} certificate file is renewd."
      __UPD=1
    ;;
    1)	# Error
      echo "Error: acme.sh exits with errors in ${__DOM}. exec this with -V and check LOG."
      [ "${__DBG}" -ne 0 ] && cu_debug "Error: acme.sh exits with errors in ${__DOM}. exec this with -V and check LOG."
      continue
    ;;
    2)	# Skip to issue/renew certificate.
      echo "${__DOM} not changed. Skip it."
      __UPD=0
    ;;
    *)	# Unknown result.
      echo "Error: acme.sh exits with unknown error."
      [ "${__DBG}" -ne 0 ] && cu_debug "Error: acme.sh exits with unknown error."
      continue
    ;;
    esac
  fi

  # distribute new cert files.
  if [ "${__DIST}" -ne 0 ]; then

    # Not update and not force distribute, skip to distribute cert files.
    [ "${__UPD}" -eq 0 -a ${__FORCE} -eq 0 ] && continue

    CU_SSH_OPT="-q -o ControlMaster=auto -o ControlPath=/tmp/acme-%r@%h:%p -o ControlPersist=5"
    __TGT=`echo "${__LINE__}" | sed -e "s/[^|]*|//" -e "s/[#].*$//" -e "s/[ ${__TAB}]*$//"`
    [ "${__DBG}" -ne 0 ] && cu_debug "DOMAIN: ${__DOM}" && cu_debug "TARGET: ${__TGT}"
    [ -z "${__TGT}" ] && echo "${__DOM} has no target host" && continue

    for i in ${__TGT}; do
      __TGTADDR=${i%%:/*}; [ ${__DBG} -ne 0 ] && cu_debug "TargetAddr: ${__TGTADDR}"
      __TGTDIR=${i##*:};   [ ${__DBG} -ne 0 ] && cu_debug "TargetDir:  ${__TGTDIR}"

      # open ssh connection with Control master
      sudo -u ${__DUSER} ssh ${CU_SSH_OPT} -N -f ${__TGTADDR}

      # Execute
      # Create TEMP Dir
      __TMPDIR=`sudo -u ${__DUSER} ssh -n ${CU_SSH_OPT} ${__TGTADDR} mktemp -d`

      sudo -u ${__DUSER} scp ${CU_SSH_OPT} ${__WORK}/${__DOM}/fullchain.cer ${__TGTADDR}:${__TMPDIR}/${__DOM}.cert
      sudo -u ${__DUSER} scp ${CU_SSH_OPT} ${__WORK}/${__DOM}/${__DOM}.key  ${__TGTADDR}:${__TMPDIR}/${__DOM}.key

      cat << __END__ | ( sudo -u ${__DUSER} ssh ${CU_SSH_OPT} ${__TGTADDR} "cat - | /bin/sh" ) >> ${__LOG}
sudo chown root:wheel ${__TMPDIR}/${__DOM}.cert ${__TMPDIR}/${__DOM}.key
sudo chmod 444        ${__TMPDIR}/${__DOM}.cert
sudo chmod 400        ${__TMPDIR}/${__DOM}.key
sudo mv ${__TMPDIR}/${__DOM}.cert ${__TMPDIR}/${__DOM}.key ${__TGTDIR}
for i in nginx postfix dovecot; do
  which \${i} > /dev/null 2>&1
  [ \$? -eq 0 ] && echo "restart \${i}" && sudo service \${i} restart 2>&1
done
__END__
# ***** WARNING *****
# mktemp -d is not defined on POSIX but many of OS has mktemp -d.
# This will be removed and replace to 
#     https://github.com/ShellShoccar-jpn/misc-tools/blob/master/mktemp
# Reload certificate file routine is temporaly impremented. This is hardcoded and agry.
# This must be rewrite with configurable.
# ***** WARNING *****

      # Postpone
      sudo -u ${__DUSER} ssh         -n ${CU_SSH_OPT} ${__TGTADDR} rm -rf ${__TMPDIR}
      sudo -u ${__DUSER} ssh -O exit ${CU_SSH_OPT} ${__TGTADDR}
    done
  fi
  echo "${__DOM} is done."
done < ${__DOMF}
