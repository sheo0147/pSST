#! /bin/sh

################################################################################
# Prepareing
################################################################################

: ${DEBUG:=0}
: ${DEBUG_ECHO:=0}
: ${FORCE_DIST:=0}
: ${DIST_ONLY:=0}
: ${FORCE_UPDATE:=0}

: ${DUSER:=""}
: ${ACME_BASE:=""}

[ -z ${DUSER} ] && echo "Please set distributers account name to DUSER" && exit 1
[ -z ${ACME_BASE} ] && echo "Please set Base Directory to ACME_BASE environmenr" && exit 1

while getopts DEdou __FLAG; do
  case "${__FLAG}" in
  D) # DEBUG
     DEBUG=1
  ;;
  E) # echo the command and not exec
     DEBUG_ECHO=1
  ;;
  d) # Force Distribute
     FORCE_DIST=1
  ;;
  o) # Distribute Only
     DIST_ONLY=1
     FORCE_DIST=1
  ;;
  u) # Force Update
     FORCE_UPDATE=1
  ;;
  *) # Default
     echo "${0}: Error."
     echo "Usage: ${0} [-DEdou]"
     echo "    -D: DEBUG print"
     echo "    -E: Echo only to execute command"
     echo "    -d: Force Distribute"
     echo "    -o: Distribute Certificate file without update"
     echo "    -u: Force Update"
     exit 1
  ;;
  esac
done

################################################################################
# Initialize
################################################################################

TAB=$'\t'
SAN=""
ACME_OPTS="-bnN"
PATH="/usr/local/bin:${PATH}"

ECHO=""; [ ${DEBUG_ECHO} -ne 0 ] && ECHO="/bin/echo"
ACCKEY="${ACME_BASE}/SSL/privkey.pem"
SSL_DIR="${ACME_BASE}/SSL"
CHALLENGE="${ACME_BASE}/htdocs"
DOMAINSFILE="${ACME_BASE}/domains.txt"
LE_ERRORED_DOMAIN=""
DI_ERRORED_DOMAIN=""
SANTMP=`mktemp /tmp/san.XXXXXXXX` || exit 1
TEMPFILE=`sudo -u ${DUSER} mktemp /tmp/crt.XXXXXXXX` || exit 1
RMTCMDS=`sudo -u ${DUSER} mktemp /tmp/crt.XXXXXXXX` || exit 1

[ ${DEBUG} -ne 0 ] && ACME_OPTS="${ACME_OPTS} -v"
[ ${FORCE_UPDATE} -ne 0 ] && ACME_OPTS="${ACME_OPTS} -F"
CUR_UID=`id -u`

if [ ${DEBUG} -ne 0 ]; then
  echo "----- DEBUG -----"
  echo "ACME_OPTS=${ACME_OPTS}"
  echo "EXEC UID=${CUR_UID}"
  echo "ECHO=\"${ECHO}\""
  echo "===== DEBUG end ====="
fi

[ ${CUR_UID} -ne 0 ] && echo "Must run by root/UID=0" && exit
[ ! -d ${ACME_BASE} ] && echo "${ACME_BASE} dir is not exist" && exit
[ ! -e ${DOMAINSFILE} ] && echo "Error: Dose not exist ${DOMAINSFILE}" && exit 1

for i in ${SSL_DIR} ${CHALLENGE}; do
  if [ ! -d ${i} ]; then
    mkdir ${i} || (echo "Error: Did not make ${i}" && exit 1)
  fi
done

################################################################################
# Main routine
################################################################################

# Main loop
cat ${DOMAINSFILE} | while read DOMS_LINE ; do
  DOMAIN=`echo ${DOMS_LINE} | sed 's/[#|].*$//'`
  [ -z ${DOMAIN} ] && continue

  # Get CERT file from Let's Encrypt by acme-client

  echo ""
  echo "Getting ${DOMAIN} Certificates"
  DOMKEY=${SSL_DIR}/${DOMAIN}/privkey.pem
  [ ! -d ${SSL_DIR}/${DOMAIN} ]   && ${ECHO} mkdir ${SSL_DIR}/${DOMAIN}

  # Get Subject Alternative Names
  SANO=0
  SANC=0
  echo "" > ${SANTMP}
  if [ -e "${ACME_BASE}/${DOMAIN}" ]; then
    for i in `cat ${ACME_BASE}/${DOMAIN} | sed -E -e 's/#.*$//' -e "s/[ ${TAB}]+$//"`; do
      SAN="${SAN} ${i}"
      echo ${i} >> ${SANTMP}
    done
    SANO=`cat ${SANTMP} | sed -E -e '/^$/d' | wc -l | awk '{print $1}'`
    SANC=`cat ${SANTMP} | sed -E -e '/^$/d' | sort | uniq | wc -l | awk '{print $1}'`
    [ ${DEBUG} -ne 0 ] && echo "SANC=${SANC}, SANO=${SANO}, SAN=${SAN}"
  fi

  if [ ${DIST_ONLY} -eq 0 ]; then
    if [ ${SANC} -eq 0 ]; then
      ${ECHO} /usr/local/bin/acme-client ${ACME_OPTS} -k ${DOMKEY} -f ${ACCKEY} -C ${CHALLENGE} -c ${SSL_DIR}/${DOMAIN} ${DOMAIN}
      RESULT=$?
    else
      if [ ${SANO} -ne ${SANC} ]; then
        echo "Error: ${DOMAIN}: some SAN duplicates."
        RESULT=1
      else
        if [ ${SANC} -gt 100 ]; then
          echo "Error: ${DOMAIN}: SAN is defineded more than 100. Do not update certs."
          RESULT=1
        else
          ${ECHO} /usr/local/bin/acme-client ${ACME_OPTS} -k ${DOMKEY} -f ${ACCKEY} -C ${CHALLENGE} -c ${SSL_DIR}/${DOMAIN} ${SAN}
          RESULT=$?
        fi
      fi
    fi
  fi

  [ ${FORCE_DIST} -ne 0 ] && RESULT=0

  # Distribute Certificate file to target machines.

  case ${RESULT} in
    0) echo "${DOMAIN} is updated. Transfer key files to servers."
       TARGET=`echo ${DOMS_LINE} | sed 's/.*|//' | sed 's/[\t ]*#.*$//'`
       [ ${DEBUG} -ne 0 ] && echo "DOMAIN: ${DOMAIN}" && echo "TARGET: ${TARGET}"
       [ -z "${TARGET}" ] && echo "${DOMAIN} has no target host" && continue

       for j in ${TARGET}; do
         TARGETADDR=${j%%:/*}; [ ${DEBUG} -ne 0 ] && echo "TargetAddr: ${TARGETADDR}"
         TARGETDIR=${j##*:};   [ ${DEBUG} -ne 0 ] && echo "TargetDitr: ${TARGETDIR}"
         echo ${TARGETADDR} >> ${TEMPFILE}
         ${ECHO} chmod 444 ${SSL_DIR}/${DOMAIN}/privkey.pem
         ${ECHO} sudo -u ${DUSER} scp -q -rp ${SSL_DIR}/${DOMAIN}/fullchain.pem ${TARGETADDR}:${DOMAIN}.cert
         ${ECHO} sudo -u ${DUSER} scp -q -rp ${SSL_DIR}/${DOMAIN}/privkey.pem   ${TARGETADDR}:${DOMAIN}.key

         ########################################
         echo "#! /bin/sh" > ${RMTCMDS}
         cat << __END_OF_FILE__ | egrep -v '(^#|^$)' >> ${RMTCMDS}
#!/bin/sh
###############################################################################
[ ! -e ${TARGETDIR} ] && mkdir ${TARGETDIR} && chmod 755 ${TARGETDIR}
[ ! -d ${TARGETDIR} ] && echo "Error!!! ${TARGET} is exist but not Directory."

mv ${DOMAIN}.cert ${DOMAIN}.key ${TARGETDIR}
chown root:wheel ${TARGETDIR}/${DOMAIN}.cert ${TARGETDIR}/${DOMAIN}.key
chmod 400 ${TARGETDIR}/${DOMAIN}.key

for i in nginx postfix dovecot; do
  which \${i};   [ \$? -eq 0 ] && echo "restart \${i}" && service \${i} restart
done
##### Post execute.
rm ./rmtcmds.sh
###############################################################################
__END_OF_FILE__

         ${ECHO} sudo -u ${DUSER} scp -q ${RMTCMDS} ${TARGETADDR}:rmtcmds.sh
         ${ECHO} rm ${RMTCMDS}
         ROOTCMD="/bin/sh rmtcmds.sh"
         ${ECHO} sudo -u ${DUSER} ssh -qtn ${TARGETADDR} sudo ${ROOTCMD}
       done
       echo "${DOMAIN} done."
       ;;
    1) echo "${DOMAIN} is troubled. Check please."
       LE_ERRORED_DOMAIN="${LE_ERRORED_DOMAIN}, ${DOMAIN}:${RESULT}"
       ;;
    2) echo "${DOMAIN} doesn't need to update"
       ;;
    *) echo "Unknown status of acme-client. Cehck please."
       LE_ERRORED_DOMAIN="${LE_ERRORED_DOMAIN}, ${DOMAIN}:${RESULT}"
       ;;
  esac
done
[ ! -z ${LE_ERRORED_DOMAIN} ] && echo "acme-client errored domain:" && echo "${LE_ERRORED_DOMAIN}"
[ ! -z ${DI_ERRORED_DOMAIN} ] && echo "distribute errored domain:" && echo "${DI_ERRORED_DOMAIN}"
