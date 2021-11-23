#!/bin/bash

JOBLIMIT=${JOBLIMIT:-50};

LINTER=$(which prettier);
LINTER=${LINTER:+"${LINTER} --write"};

FILEEXT=".map"; # removes anyting after $EXT in the URL

# check if a url has been supplied
if [ -z "$1" ]; then
  echo "Please supply a sourcemap URL"
  exit 1;
fi

# store url with sourcemap filename
URL="$1"
OUTPUTDIR="$2"

if [[ ! -z ${OUTPUTDIR} ]]; then
  OUTPUTDIR="$(realpath ${OUTPUTDIR})";
  mkdir -p ${OUTPUTDIR};
fi

# store url without sourcemap filename
URLNOMAP=$(echo $URL | rev | cut -d '/' -f2- | rev)

# check if url is sourcemap or js
if [ $(echo $URL | rev | awk -F'.' '{print $1}' | rev) != 'map' ]; then
  # If not .map check for a sourcemap reference
  if [[ -z ${OUTPUTDIR+x} ]]; then
     _MAPFILE=$(mktemp);
  else
    _MAPFILE="${OUTPUTDIR}/index.js";
  fi

  curl -s "${URL}" > ${_MAPFILE};

  MAPFILE=$(cat ${_MAPFILE} | grep sourceMapping | sed -e 's/.*sourceMappingURL=\([[:alnum:][:punct:]]*\)/\1/' | sed "s/\\${FILEEXT}.*/${FILEEXT}/" | awk '{ print $1 }')
  if [ -z ${MAPFILE+x} ]; then
    echo "No sourcemap referenced in $URL"
    exit 1
  fi
  URL="$URLNOMAP/$MAPFILE"
  echo "Found reference to $URL"
fi

# check if file exists at all
RESP=$(curl -s -o /dev/null -w "%{http_code}" -- $URL)
if [ "$RESP" != '200' ]; then
  echo "Map not found. ($URL) (HTTP Response Code: $RESP)";
  exit 1;
fi

# pull contents of the file into $MAP
if [[ -z ${OUTPUTDIR+x} ]]; then
  TMPFILE=$(mktemp);
else
  TMPFILE="${OUTPUTDIR}/index.js.map";
fi

curl -s "$URL" > ${TMPFILE};

function MAP () {
  cat ${TMPFILE};
}

# is it even valid json?
MAP | jq > /dev/null 2>&1
if [ $? != 0 -a $? != 2 ]; then
  echo "Map contains invalid JSON."
  exit 1;
fi

# Version?
VER=$(MAP | jq '.version' 2> /dev/null);
if [ "$VER" != '3' ]; then
    echo "This tool has only been tested with version 3 of the sourcemap spec."
    echo "the requested sourcemap returned a version of: $VER. Trying anyway."
fi

echo "Map loaded: read $(MAP | wc -c) bytes from $(echo $URL | rev | awk -F'/' '{print $1}' | rev)."

# get the number of files, the directory structure, and the file contents
LENGTH=$(MAP | jq '.sources[]' 2> /dev/null | wc -l);
CONTENTS=$(MAP | jq '.sourcesContent' 2> /dev/null );
SOURCES=$(MAP | jq '.sources' 2> /dev/null );

echo "$LENGTH files to be written."
COUNTER=$LENGTH

BASE=${OUTPUTDIR:-'./sourcemaps'};
set -o noglob;
for ((i=0;i<=LENGTH;i++)); do
  function loop () {
    # for each file: get the path without the filename, remove ../'s, remove quotes
    P=$(echo $SOURCES | jq .[$i] | rev | cut -d '/' -f2- | rev | sed 's/\"//g');
    # get the filename without the path
    F=$(echo $SOURCES | jq .[$i] | rev | awk -F'/' '{print $1}' | rev | sed 's/\"//g');

    # check for source in sourcesContent, otherwise get directly from the URL.
    DATA=$(echo ${CONTENTS}| jq .[$i]);
    if [ "$DATA" == 'null' ]; then
      DATA=$(curl -s "$URLNOMAP/$P/$F");
    fi;

    DATA=$(echo ${DATA} | sed 's/\\"/"/g');

    # create directories to match the paths in the map, eliminate ../'s
    P=$(echo $P | sed 's/\.\.\///g');
    mkdir -p "$BASE/$P";

    # create the file at that location
    printf "%b\n" "$(printf '%s' "${DATA}" | sed -e 's/%/%%/g' -e 's/^"//' -e 's/"$//')" > "$BASE/$P/$F";
    echo -ne "\rWriting: $BASE/$P/$F\n";
  }

  printf "\r$COUNTER files remaining.";
  JOBS=$(jobs -p | wc -l);

  if [[ JOBS -lt JOBLIMIT ]]; then
    loop &
  else
    loop
  fi

  ((COUNTER=COUNTER-1))
done

wait;
[[ ! -z $LINTER ]] && ${LINTER} $(realpath ${BASE})

exit 0;
