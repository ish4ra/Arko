#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/engine-tests
python3 scripts/build-sevenzip.py --output .build/sevenzip
export LD_LIBRARY_PATH="$PWD/.build/sevenzip${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DYLD_LIBRARY_PATH="$PWD/.build/sevenzip${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
if [[ $(uname -s) == Darwin ]]; then
  library=.build/engine-tests/libarkiv.dylib
  cc -std=c11 -Wall -Wextra -Werror -dynamiclib -I Sources/CArkiv/include Sources/CArkiv/ArkivArchive.c -larchive -L .build/sevenzip -lArkivSeven -Wl,-rpath,"$PWD/.build/sevenzip" -o "$library"
else
  library=.build/engine-tests/libarkiv.so
  cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -shared -fPIC ${ARKIV_CFLAGS:-} -I Sources/CArkiv/include Sources/CArkiv/ArkivArchive.c -Wl,-l:libarchive.so.13 -L .build/sevenzip -lArkivSeven -Wl,-rpath,"$PWD/.build/sevenzip" -o "$library"
fi
ARKIV_TEST_LIBRARY="$PWD/$library" python3 tests/test_engine.py -v

ARKIV_TEST_LIBRARY="$PWD/$library" python3 tests/test_creation.py -v

ARKIV_SEVEN_LIBRARY="$PWD/.build/sevenzip/$(basename "$library" | sed "s/libarkiv/libArkivSeven/")" python3 tests/test_sevenzip.py -v

ARKIV_TEST_LIBRARY="$PWD/$library" python3 tests/test_integrity.py -v

ARKIV_TEST_LIBRARY="$PWD/$library" python3 tests/test_zip_addition.py -v
