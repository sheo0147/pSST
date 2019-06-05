parse_yaml() { # Usage: parse_yaml file EnvPrefix
  [ ! -f "${1}" ] && echo "\"${1}\" not found." && exit 1
  [ -z "${2}" ] && echo "Must need prefix." && exit 1
  cat $1 | awk '
    BEGIN { TARGET="" }
    {
      sub(/[\t ]*#.*$/,"",$0)
      if(length($0) == 0) { next }
      LINE=$0; sub(/^[\t ]+/,"",LINE)
      INDENT=(length($0)-length(LINE))/2
      KEY=LINE; sub(/:.*/,"",KEY)
      VALUE=LINE; sub(/[^:]*:[\t ]*/,"",VALUE)
    
      if( KEY ~ /^-[ ]*/ ) {} else { VNAME[INDENT] = ("_")(KEY) }
      for( i in VNAME ) {if( i > INDENT ) {delete VNAME[i]}}
      if( length(VALUE) > 0 ) {
        if( match(VALUE, /\[.*]$/)) {
          VALUE=substr(VALUE, RSTART+1, RLENGTH-2)
          gsub( /,/, " ", VALUE )
          gsub( /^[\t ]+/, "", VALUE )
          gsub( /[\t ]+$/, "", VALUE )
        }
        gsub( /"/, "\\\"" ,VALUE )
      }
      if( INDENT == 0 ) { TARGET=(TARGET)(" ")(KEY) }
      vn=""; for (i=0; i <= INDENT; i++) {vn=( vn )( VNAME[i] ) }
      if( KEY ~ /^-[ ]*/ ) {
        gsub( /^-[ ]*/, "", KEY )
        printf( "%s%s=\"${%s%s} %s\";\n", "'${2}'", vn, "'${2}'", vn, KEY )
      } else {
        printf( "%s%s=\"%s\";\n", "'${2}'", vn, VALUE )
      }
    }
    END{
        printf( "%s_TGT=\"%s\";\n", "'${2}'", TARGET )
    }'
}
