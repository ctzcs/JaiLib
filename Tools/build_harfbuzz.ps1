param([string]$BuildRoot = "$PSScriptRoot/../.test_tmp/harfbuzz-rebuild")
$ErrorActionPreference = 'Stop'
$revision = '33a3f8de60dcad7535f14f07d6710144548853ac'
$source = Join-Path $BuildRoot 'source'
$build = Join-Path $BuildRoot 'build'
$destination = Join-Path $PSScriptRoot '../Libs/Engine/text/windows'
if (!(Test-Path -LiteralPath $source)) {
    git clone --depth 1 --branch 11.2.1 https://github.com/harfbuzz/harfbuzz.git $source
    if ($LASTEXITCODE) { throw 'HarfBuzz clone failed' }
}
$actual = git -C $source rev-parse HEAD
if ($actual -ne $revision) { throw "Unexpected HarfBuzz revision: $actual" }
cmake -S $source -B $build -DBUILD_SHARED_LIBS=ON -DHB_BUILD_SUBSET=OFF -DHB_BUILD_UTILS=OFF -DHB_BUILD_TESTS=OFF -DHB_HAVE_FREETYPE=OFF -DHB_HAVE_GLIB=OFF -DHB_HAVE_ICU=OFF -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
if ($LASTEXITCODE) { throw 'HarfBuzz configure failed' }
cmake --build $build --config Release --target harfbuzz --parallel 4
if ($LASTEXITCODE) { throw 'HarfBuzz build failed' }
New-Item -ItemType Directory -Force $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $build 'Release/harfbuzz.dll') -Destination $destination
Copy-Item -LiteralPath (Join-Path $build 'Release/harfbuzz.lib') -Destination $destination
Copy-Item -LiteralPath (Join-Path $source 'COPYING') -Destination (Join-Path $PSScriptRoot '../Libs/Engine/text/HarfBuzz.LICENSE')
