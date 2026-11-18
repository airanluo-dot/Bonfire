import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const website = fileURLToPath(new URL('../', import.meta.url));
const source = join(website, '_source');
const output = join(website, 'dist');
const feedPath = join(website, 'tools', 'releases.snapshot.json');
const repository = 'airanluo-dot/Bonfire';
const releasesUrl = 'https://github.com/' + repository + '/releases';
const sourceApi = 'repos/' + repository + '/releases';
const tagPattern = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:beta|preview)\.([1-9]\d*))?$/;
const kinds = {
  windows: { installer: 'Windows-x64-Setup.exe', portable: 'Windows-x64-Portable.zip' },
  macos: { installer: 'macOS-arm64-Installer.pkg', portable: 'macOS-arm64-Portable.zip' },
};
const json = value => JSON.stringify(value, null, 2) + '\n';

function requireValue(value, message) {
  if (!value) throw new Error(message);
}

function compareVersions(a, b) {
  const aa = tagPattern.exec(a.version), bb = tagPattern.exec(b.version);
  for (let i = 1; i <= 4; i++) {
    if (aa[i] === undefined || bb[i] === undefined) {
      if (aa[i] === bb[i]) return 0;
      return aa[i] === undefined ? -1 : 1;
    }
    const left = BigInt(aa[i]), right = BigInt(bb[i]);
    if (left !== right) return left > right ? -1 : 1;
  }
  return 0;
}

function validateAsset(asset, release, expectedName) {
  requireValue(asset && asset.name === expectedName &&
    asset.url === releasesUrl + '/download/' + release.tag + '/' + expectedName &&
    Number.isSafeInteger(asset.size) && asset.size > 0 && /^[a-f0-9]{64}$/.test(asset.sha256),
    'Invalid asset: ' + expectedName);
}

function checkedSnapshot(releases) {
  requireValue(Array.isArray(releases) && releases.length, 'No public releases found');
  const seen = new Set();
  for (const r of releases) {
    const match = tagPattern.exec(r.tag);
    requireValue(match && !seen.has(r.tag) && r.tag === 'v' + r.version &&
      r.channel === (match[4] ? 'beta' : 'stable') &&
      r.htmlUrl === releasesUrl + '/tag/' + r.tag && typeof r.name === 'string' &&
      typeof r.summary === 'string' && typeof r.publishedAt === 'string' && Number.isFinite(Date.parse(r.publishedAt)),
      'Invalid release: ' + r.tag);
    seen.add(r.tag);
    validateAsset(r.checksums, r, 'SHA256SUMS.txt');
    for (const [platform, files] of Object.entries(kinds)) {
      for (const [kind, suffix] of Object.entries(files)) {
        validateAsset(r.platforms[platform][kind], r, 'Bonfire-' + r.version + '-' + suffix);
      }
    }
  }
  releases.sort(compareVersions);
  return {
    schemaVersion: 1, releasesUrl, currentVersion: releases[0].version,
    current: releases[0],
    latest: releases[0], stable: releases.find(r => r.channel === 'stable') ?? null,
    beta: releases.find(r => r.channel === 'beta') ?? null, releases,
  };
}

function ghApi(args) {
  return execFileSync('gh', ['api', ...args], { maxBuffer: 32 * 1024 * 1024, timeout: 90000, windowsHide: true });
}

function readPublicRelease(raw) {
  const version = raw.tag_name.slice(1);
  const release = {
    tag: raw.tag_name, version, name: raw.name || raw.tag_name,
    channel: raw.prerelease ? 'beta' : 'stable', publishedAt: raw.published_at, htmlUrl: raw.html_url,
    summary: (raw.body || '').trim().split(/\r?\n\s*\r?\n/)[0], platforms: {},
  };
  function select(name) {
    const matches = raw.assets.filter(a => a.state === 'uploaded' && a.name === name);
    requireValue(matches.length === 1, 'Missing or duplicate ' + name + ' in ' + raw.tag_name);
    const a = matches[0];
    requireValue(/^sha256:[a-f0-9]{64}$/.test(a.digest), 'Missing SHA-256: ' + name);
    return { id: a.id, asset: {name, url: a.browser_download_url, size: a.size, sha256: a.digest.slice(7)} };
  }
  const checksum = select('SHA256SUMS.txt');
  release.checksums = checksum.asset;
  const manifest = ghApi(['-H', 'Accept: application/octet-stream', sourceApi + '/assets/' + checksum.id]);
  requireValue(manifest.length === checksum.asset.size &&
    createHash('sha256').update(manifest).digest('hex') === checksum.asset.sha256, 'Corrupt SHA256SUMS for ' + raw.tag_name);
  const hashes = new Map();
  for (const line of manifest.toString('utf8').trimEnd().split(/\r?\n/)) {
    const row = /^([a-f0-9]{64}) [ *]([^/\\]+)$/.exec(line);
    requireValue(row && !hashes.has(row[2]), 'Invalid checksum manifest for ' + raw.tag_name);
    hashes.set(row[2], row[1]);
  }
  for (const [platform, files] of Object.entries(kinds)) {
    release.platforms[platform] = {};
    for (const [kind, suffix] of Object.entries(files)) {
      const {asset} = select('Bonfire-' + version + '-' + suffix);
      requireValue(hashes.get(asset.name) === asset.sha256, 'Checksum mismatch: ' + asset.name);
      release.platforms[platform][kind] = asset;
    }
  }
  return release;
}

async function refresh() {
  const pages = JSON.parse(ghApi(['--paginate', '--slurp', sourceApi + '?per_page=100']));
  const releases = pages.flat().filter(r => !r.draft && r.published_at && tagPattern.test(r.tag_name));
  const snapshot = checkedSnapshot(releases.map(readPublicRelease));
  const tempFile = feedPath + '.' + process.pid + '.tmp';
  try {
    await writeFile(tempFile, json({ schemaVersion: 1, releases: snapshot.releases }));
    await rename(tempFile, feedPath);
  } finally {
    await rm(tempFile, { force: true });
  }
  console.log('Refreshed ' + releases.length + ' verified public releases.');
}

function platformRelease(release, platform) {
  if (!release) return null;
  const { platforms, ...details } = release;
  return { ...details, assets: platforms[platform] };
}

async function writeApi(root, feed) {
  async function emit(relativeFile, data) {
    const destination = join(root, relativeFile);
    await mkdir(dirname(destination), { recursive: true });
    await writeFile(destination, json(data));
  }
  await emit('release-data.json', feed);
  for (const platform of Object.keys(kinds)) {
    const directory = platform === 'windows' ? 'api/v1' : 'api/macos/v1';
    const envelope = { schemaVersion: 1, platform, currentVersion: feed.currentVersion };
    await emit(directory + '/releases.json', { ...envelope, releases: feed.releases.map(r => platformRelease(r, platform)) });
    for (const channel of ['stable', 'beta']) {
      // Beta subscribers also receive a newer stable release, as in the native app.
      const eligible = channel === 'beta' ? feed.latest : feed.stable;
      await emit(directory + '/' + channel + '.json', { ...envelope, channel, release: platformRelease(eligible, platform) });
    }
  }
  const {tag, name, htmlUrl, summary, publishedAt} = feed.latest;
  await emit('api/v1/latest-change.json', { schemaVersion: 1, tag, name, htmlUrl, summary, publishedAt });
}

async function fingerprintWorkbenchImage(root) {
  const original = 'assets/workbench-windows.png';
  const digest = createHash('sha256').update(await readFile(join(root, original))).digest('hex');
  const versioned = 'assets/workbench-windows.' + digest.slice(0, 16) + '.png';
  const page = join(root, 'index.html');
  const html = await readFile(page, 'utf8');
  const imageSrc = 'src="' + original + '"';
  requireValue(html.includes(imageSrc), 'Missing workbench screenshot in index.html');
  await rename(join(root, original), join(root, versioned));
  await writeFile(page, html.replaceAll(imageSrc, 'src="' + versioned + '"'));
}

async function build() {
  const snapshot = JSON.parse(await readFile(feedPath, 'utf8'));
  requireValue(snapshot.schemaVersion === 1, 'Unsupported release snapshot format');
  const feed = checkedSnapshot(snapshot.releases);
  const scratch = await mkdtemp(join(website, '.build-'));
  const next = join(scratch, 'next'), previous = join(scratch, 'previous');
  let moved = false, safeToClean = true;
  try {
    await cp(source, next, { recursive: true });
    await fingerprintWorkbenchImage(next);
    // Use the app sources shipped to users, even while main is developing the next version.
    const archive = join(scratch, 'catalog.zip');
    execFileSync('git', ['archive', '--format=zip', '-o', archive, 'refs/tags/' + feed.current.tag,
      '--', 'VERSION', 'README.md', 'branding/Bonfire.svg', 'adapters'], {cwd: join(website, '..'), windowsHide: true});
    const python = process.platform === 'win32' ? 'py' : 'python3';
    const args = process.platform === 'win32' ? ['-3'] : [];
    execFileSync(python, [...args, join(website, 'tools', 'catalog.py'),
      '--archive', archive, '--version', feed.currentVersion, '--output-root', next], { stdio: 'inherit', windowsHide: true });
    await writeApi(next, feed);
    await stat(join(next, 'index.html'));
    await writeFile(join(next, '.bonfire-site-build'), 'Bonfire static website\n');
    try {
      await stat(output);
      await stat(join(output, '.bonfire-site-build'));
      await rename(output, previous);
      moved = true;
    } catch (err) {
      if (err.code !== 'ENOENT' || err.path !== output) throw err;
    }
    try {
      await rename(next, output);
    } catch (err) {
      if (moved) {
        safeToClean = false;
        await rename(previous, output);
        safeToClean = true;
      }
      throw err;
    }
    console.log('Built ' + output + ' (current public release: ' + (feed.current?.tag || 'unpublished') + ')');
  } finally {
    if (safeToClean) await rm(scratch, { recursive: true, force: true });
  }
}

const command = process.argv[2] ?? 'build';
if (command === 'refresh') await refresh();
else if (command === 'build') await build();
else if (command === 'release-build') {
  await refresh();
  await build();
} else throw new Error('Expected build, refresh or release-build');
