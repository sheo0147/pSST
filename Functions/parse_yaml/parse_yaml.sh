#! /bin/sh
parse_yaml() {
# Usage: parse_yaml configFile Prefix
  [ ! -f "${1}" ] && echo "\"${1}\" not found." && exit 1
  [ -z "${2}" ] && echo "Must need prefix." && exit 1
  cat $1 | awk '
    {
      sub(/[\t ]*#.*$/,"",$0);
      if(length($0) == 0) { next }
      LINE=$0;
      sub(/[\t ]+/,"",LINE);
      INDENT=(length($0)-length(LINE))/2;
      KEY=LINE; VALUE=LINE
      sub(/:.*/,"",KEY);
      sub(/[^:]*:[\t ]*/,"",VALUE);
    
      if( KEY ~ /^-[ ]*/ ) {} else {
        VNAME[INDENT] = ("_")(KEY);
      }
      for( i in VNAME ) {if ( i > INDENT ) {delete VNAME[i]}}
      if ( length(VALUE) > 0 ) {
        if( match(VALUE, /\[.*]$/)) {
          VALUE=substr(VALUE, RSTART+1, RLENGTH-2)
          gsub( /,/ , " ", VALUE )
          gsub( /^[\t ]+/, "", VALUE )
          gsub( /[\t ]+$/, "", VALUE )
        }
        gsub( /"/, "\\\"" ,VALUE );
      }
      vn=""
      for (i=0; i <= INDENT; i++) {vn=(vn)(VNAME[i])}
      if( KEY ~ /^-[ ]*/ ) {
        gsub( /^-[ ]*/, "", KEY )
        #printf("%s%s=\"${%s%s} \\\"%s\\\"\";\n", "'${2}'", vn, "'${2}'", vn, KEY);
        printf("%s%s=\"${%s%s} %s\";\n", "'${2}'", vn, "'${2}'", vn, KEY);
      } else {
        printf("%s%s=\"%s\";\n", "'${2}'", vn, VALUE);
      }
    }'
}

read_eval_yaml_config() {
# Usage: read_eval_yaml_config configFile Prefix Tempdir
  [ ! -f "${1}" ] && echo "\"${1}\" not found." && exit 1
  [ -z "${2}" ] && echo "Must need prefix." && exit 1
  [ -z "${3}" ] && TMPDIR=${3} || TMPDIR=$(mktemp -d /tmp/parse.XXXXX)

  parse_yaml ${1} ${2}
echo "====="
  parse_yaml ${1} ${2} > ${TMPDIR}/ptmp
  . ${TMPDIR}/ptmp
  rm -rf ${TMPDIR}
}
