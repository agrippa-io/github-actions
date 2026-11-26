#!/usr/bin/env node
// The SDK release planner (docs-platform-0 15.7). One planner for all three SDK
// repos (sdk-typescript, sdk-python, sdk-java), so the same docs change always
// gives the same version bump in every language.
//
// For each SDK in the manifest (sdks.json: { "<source key>": { "version", "package"? } }):
//   1. fetch the source's client model from the docs service (versions/<version>/sdk-model);
//   2. compare it with the pinned model (models/<key>.json): identical → no release;
//   3. otherwise ask the docs service for the 2.6 version diff between the pinned
//      model's docs version and the new one (GET /sources/:key/diff):
//        breaking → major · any other change → minor · nothing in the diff → patch.
//      The same docs version with a different model (a generator update) is a patch.
//      When the diff can't be read (the old version isn't in this docs service),
//      the release is treated as breaking: a major never breaks a client, a missed one does;
//   4. with --write: store the new model, bump the manifest version, add a CHANGELOG section.
//
// Writes the plan as JSON (--plan-out) and, on GitHub Actions, the outputs
// `changed`, `bump` and `plan`, plus a step summary. No dependencies: Node >= 20.

import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

export const BUMPS = ['none', 'patch', 'minor', 'major']
export const MAX_CHANGES = 50

/** The larger of two bumps. */
export const maxBump = (a, b) => (BUMPS.indexOf(a) >= BUMPS.indexOf(b) ? a : b)

/** `1.2.3` (a pre-release or build suffix is dropped) bumped by `bump`. */
export const bumpVersion = (version, bump) => {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(String(version))
  if (!match) throw new Error(`not a semver version: ${JSON.stringify(version)}`)
  const [major, minor, patch] = match.slice(1).map(Number)
  if (bump === 'major') return `${major + 1}.0.0`
  if (bump === 'minor') return `${major}.${minor + 1}.0`
  if (bump === 'patch') return `${major}.${minor}.${patch + 1}`
  return `${major}.${minor}.${patch}`
}

/** The bump a 2.6 diff report calls for. */
export const bumpOfDiff = report => {
  if (report.breaking) return 'major'
  return report.summary && report.summary.total > 0 ? 'minor' : 'patch'
}

const encode = segment => encodeURIComponent(segment)

/** GET a URL; returns { status, text }. Network errors are status 0. */
const get = async (fetchImpl, url, token) => {
  const headers = { accept: 'application/json' }
  if (token) headers.authorization = `Bearer ${token}`
  try {
    const response = await fetchImpl(url, { headers })
    return { status: response.status, text: await response.text() }
  } catch (error) {
    return { status: 0, text: String(error && error.message ? error.message : error) }
  }
}

const parseModel = (text, where) => {
  let model
  try {
    model = JSON.parse(text)
  } catch {
    throw new Error(`${where}: not JSON`)
  }
  if (!model || model.format !== 'agrippa.sdk-client-model' || !model.source || typeof model.source.version !== 'string') {
    throw new Error(`${where}: not an agrippa.sdk-client-model`)
  }
  return model
}

/**
 * Plans the release of one SDK. Pure apart from `fetchImpl`.
 * `pinnedText` is the committed model (null for a new SDK), `candidateText` the docs service's.
 */
export const planSdk = async ({ key, entry, pinnedText, candidateText, docsUrl, token, fetchImpl }) => {
  const pkg = entry.package || key
  const base = { key, package: pkg, from: entry.version }
  if (pinnedText === candidateText) {
    return { ...base, to: entry.version, bump: 'none', reason: 'client model unchanged', changes: [] }
  }
  const candidate = parseModel(candidateText, `${key}: docs model`)
  const toDocs = candidate.source.version
  if (pinnedText === null) {
    return {
      ...base, to: entry.version, bump: 'patch', initial: true, fromDocs: null, toDocs,
      reason: `first release, from docs ${toDocs}`, changes: [],
    }
  }
  const fromDocs = parseModel(pinnedText, `${key}: pinned model`).source.version
  const docs = { fromDocs, toDocs }
  if (fromDocs === toDocs) {
    return {
      ...base, ...docs, to: bumpVersion(entry.version, 'patch'), bump: 'patch',
      reason: `docs ${toDocs} unchanged; the client model changed (generator update)`, changes: [],
    }
  }
  const url = `${docsUrl.replace(/\/+$/, '')}/sources/${encode(key)}/diff?from=${encode(fromDocs)}&to=${encode(toDocs)}`
  const { status, text } = await get(fetchImpl, url, token)
  if (status !== 200) {
    return {
      ...base, ...docs, to: bumpVersion(entry.version, 'major'), bump: 'major', diffStatus: status,
      reason: `no version diff ${fromDocs} → ${toDocs} (HTTP ${status}): treated as breaking`, changes: [],
    }
  }
  const report = JSON.parse(text)
  const bump = bumpOfDiff(report)
  const summary = report.summary || { total: 0, breaking: 0 }
  return {
    ...base, ...docs, to: bumpVersion(entry.version, bump), bump, diffStatus: 200,
    reason: `docs ${fromDocs} → ${toDocs}: ${summary.breaking} breaking, ${summary.total - summary.breaking} other change(s)`,
    changes: (report.changes || []).map(change => ({
      severity: change.severity,
      kind: change.kind,
      message: change.message,
      operation: change.operation ? `${change.operation.method} ${change.operation.path}` : null,
    })),
  }
}

/** Fetches every model and plans every SDK in the manifest, in manifest order. */
export const plan = async ({ manifest, modelsDir, docsUrl, docsVersion = 'latest', token, fetchImpl = fetch }) => {
  const sdks = []
  const errors = []
  for (const [key, entry] of Object.entries(manifest)) {
    const url = `${docsUrl.replace(/\/+$/, '')}/sources/${encode(key)}/versions/${encode(docsVersion)}/sdk-model`
    const { status, text } = await get(fetchImpl, url, token)
    if (status !== 200) {
      errors.push(`${key}: HTTP ${status} from ${url}`)
      continue
    }
    const pinnedPath = path.join(modelsDir, `${key}.json`)
    const pinnedText = existsSync(pinnedPath) ? readFileSync(pinnedPath, 'utf8') : null
    try {
      sdks.push({ ...(await planSdk({ key, entry, pinnedText, candidateText: text, docsUrl, token, fetchImpl })), model: text })
    } catch (error) {
      errors.push(error.message)
    }
  }
  const bump = sdks.reduce((acc, sdk) => maxBump(acc, sdk.bump), 'none')
  return { bump, changed: sdks.some(sdk => sdk.bump !== 'none'), sdks, errors }
}

const describe = sdk => {
  if (sdk.initial) return `First release, generated from docs \`${sdk.toDocs}\`.`
  if (sdk.diffStatus === 200) return `Docs \`${sdk.fromDocs}\` → \`${sdk.toDocs}\`.`
  if (sdk.diffStatus !== undefined) {
    return `Docs \`${sdk.fromDocs}\` → \`${sdk.toDocs}\`. The docs service has no diff between them (HTTP ${sdk.diffStatus}), so this release is treated as **breaking**.`
  }
  return `Regenerated from docs \`${sdk.toDocs}\` (the docs version is unchanged; the client model changed).`
}

/** The CHANGELOG section for a plan's released SDKs; '' when nothing is released. */
export const changelogSection = (result, date) => {
  const released = result.sdks.filter(sdk => sdk.bump !== 'none')
  if (released.length === 0) return ''
  const lines = [`## ${date}`, '']
  for (const sdk of released) {
    lines.push(`### \`${sdk.package}\` ${sdk.to} (${sdk.bump})`, '', describe(sdk), '')
    const shown = sdk.changes.slice(0, MAX_CHANGES)
    for (const change of shown) {
      const label = change.severity === 'breaking' ? '**Breaking** ' : ''
      const where = change.operation ? ` (\`${change.operation}\`)` : ''
      lines.push(`- ${label}\`${change.kind}\`: ${change.message}${where}`)
    }
    if (sdk.changes.length > shown.length) lines.push(`- … and ${sdk.changes.length - shown.length} more`)
    if (shown.length) lines.push('')
  }
  return lines.join('\n')
}

/**
 * Puts `section` into a changelog: after the `## Unreleased` section when there
 * is one, else right after the `# ` title, else at the top.
 */
export const insertSection = (changelog, section) => {
  if (!section) return changelog
  const lines = changelog.split('\n')
  let at = lines.findIndex(line => /^## Unreleased\b/i.test(line))
  if (at >= 0) {
    const next = lines.findIndex((line, i) => i > at && /^## /.test(line))
    at = next >= 0 ? next : lines.length
  } else {
    const title = lines.findIndex(line => /^# /.test(line))
    at = title >= 0 ? title + 1 : 0
  }
  const before = lines.slice(0, at).join('\n').replace(/\n*$/, '')
  const after = lines.slice(at).join('\n').replace(/^\n*/, '')
  return `${before ? `${before}\n\n` : ''}${section.replace(/\n*$/, '\n')}${after ? `\n${after}` : ''}`.replace(/\n*$/, '\n')
}

/** Applies a plan: new models, manifest versions and the changelog section. */
export const apply = ({ result, manifest, manifestPath, modelsDir, changelogPath, date }) => {
  const next = structuredClone(manifest)
  mkdirSync(modelsDir, { recursive: true })
  for (const sdk of result.sdks) {
    if (sdk.bump === 'none') continue
    next[sdk.key] = { ...next[sdk.key], version: sdk.to }
    writeFileSync(path.join(modelsDir, `${sdk.key}.json`), sdk.model)
  }
  writeFileSync(manifestPath, `${JSON.stringify(next, null, 2)}\n`)
  const current = existsSync(changelogPath) ? readFileSync(changelogPath, 'utf8') : '# Changelog\n'
  writeFileSync(changelogPath, insertSection(current, changelogSection(result, date)))
  return next
}

/** The step summary (Markdown). */
export const summary = result => {
  const lines = ['### SDK release plan', '', `Overall bump: **${result.bump}**`, '', '| SDK | Version | Bump | Why |', '| --- | --- | --- | --- |']
  for (const sdk of result.sdks) {
    lines.push(`| \`${sdk.package}\` | ${sdk.from}${sdk.to !== sdk.from ? ` → ${sdk.to}` : ''} | ${sdk.bump} | ${sdk.reason} |`)
  }
  for (const error of result.errors) lines.push('', `- error: ${error}`)
  return `${lines.join('\n')}\n`
}

export const parseArgs = argv => {
  const options = { manifest: 'sdks.json', models: 'models', changelog: 'CHANGELOG.md', version: 'latest', write: false }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--write') { options.write = true; continue }
    const name = arg.replace(/^--/, '')
    if (!arg.startsWith('--') || !['manifest', 'models', 'changelog', 'docs-url', 'version', 'plan-out', 'date'].includes(name)) {
      throw new Error(`unknown argument: ${arg}`)
    }
    if (i + 1 >= argv.length) throw new Error(`${arg} needs a value`)
    options[name] = argv[++i]
  }
  if (!options['docs-url']) throw new Error('--docs-url is required')
  return options
}

/** The CLI. Returns the exit code: 0 planned (and written), 1 an SDK could not be planned, 2 bad usage. */
export const main = async (argv, env = process.env, { fetchImpl = fetch, log = console.log, today = new Date() } = {}) => {
  let options
  try {
    options = parseArgs(argv)
  } catch (error) {
    log(`error: ${error.message}`)
    log('usage: plan.mjs --docs-url <url> [--manifest sdks.json] [--models models] [--changelog CHANGELOG.md] [--version latest] [--plan-out plan.json] [--date YYYY-MM-DD] [--write]')
    return 2
  }
  const manifest = JSON.parse(readFileSync(options.manifest, 'utf8'))
  const result = await plan({
    manifest, modelsDir: options.models, docsUrl: options['docs-url'], docsVersion: options.version,
    token: env.DOCS_TOKEN || '', fetchImpl,
  })
  for (const sdk of result.sdks) log(`${sdk.package}: ${sdk.bump}${sdk.bump === 'none' ? '' : ` ${sdk.from} → ${sdk.to}`} (${sdk.reason})`)
  for (const error of result.errors) log(`error: ${error}`)
  const date = options.date || today.toISOString().slice(0, 10)
  if (options['plan-out']) {
    const { sdks, ...rest } = result
    writeFileSync(options['plan-out'], `${JSON.stringify({ ...rest, sdks: sdks.map(({ model, ...sdk }) => sdk) }, null, 2)}\n`)
  }
  if (result.errors.length) return 1
  if (options.write && result.changed) {
    apply({ result, manifest, manifestPath: options.manifest, modelsDir: options.models, changelogPath: options.changelog, date })
  }
  if (env.GITHUB_OUTPUT) {
    appendFileSync(env.GITHUB_OUTPUT, `changed=${result.changed}\nbump=${result.bump}\nplan=${options['plan-out'] || ''}\n`)
  }
  if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, summary(result))
  return 0
}

// The CLI entry; the tests import the module and call main() instead.
/* node:coverage disable */
if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  process.exitCode = await main(process.argv.slice(2))
}
/* node:coverage enable */
