#!/bin/sh -

cd `mktemp -d`

# We just download the bootstrap script by default and execute that.
if [ -x /usr/bin/fetch ]; then
    /usr/bin/fetch -o bootstrap-salt.sh https://bootstrap.saltproject.io
elif [ -x /usr/bin/curl ]; then
    /usr/bin/curl --silent --show-error -L --output bootstrap-salt.sh https://bootstrap.saltproject.io
elif [ -x /usr/bin/wget ]; then
    /usr/bin/wget -O bootstrap-salt.sh https://bootstrap.saltproject.io
elif [ "2" = `python -c 'import sys; sys.stdout.write(str(sys.version_info.major))'` ]; then
    # TODO: remove after there is no supported distros with Python 2
    python -c 'import urllib; urllib.urlretrieve("https://bootstrap.saltproject.io", "bootstrap-salt.sh")'
else
    python -c 'import urllib.request; urllib.request.urlretrieve("https://bootstrap.saltproject.io", "bootstrap-salt.sh")'
fi

if [ -e bootstrap-salt.sh ]; then
  # Until Bootstrap's next official release that includes the fix, remove deprecated package source
  sed -i 's/python2-futures //g' bootstrap-salt.sh
  sh bootstrap-salt.sh "$@"
else
  exit 1
fi
