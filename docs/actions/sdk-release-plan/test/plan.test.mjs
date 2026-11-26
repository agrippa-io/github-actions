// Unit tests for plan.mjs: `node --test docs/actions/sdk-release-plan/test` (100% coverage gate in CI).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import {
  apply, bumpOfDiff, bumpVersion, changelogSection, insertSection, main, maxBump, parseArgs, plan, planSdk, summary, MAX_CHANGES,
} from '../plan.mjs'

const DOCS = 'http://docs.test/docs/v1/'
const model = (version, extra = {}) =>
  `${JSON.stringify({ format: 'agrippa.sdk-client-model', formatVersion: 1, source: { key: 'pets', version, contentHash: version }, ...extra }, null, 2)}\n`

/** A fake docs service: `routes` maps a URL (after the base) to [status, body] or a thrown error. */
const fakeFetch = (routes, calls = []) => async (url, init) => {
  calls.push({ url, auth: init.headers.authorization })
  const key = url.slice(DOCS.length - 1)
  const route = routes[key]
  if (route instanceof Error) throw route
  if (!route) return new Response('{"error":"Not found"}', { status: 404 })
  const [status, body] = route
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status })
}

const breakingDiff = {
  breaking: true,
  summary: { total: 2, breaking: 1 },
  changes: [
    { severity: 'breaking', kind: 'operation.removed', message: 'operation removed', operation: { key: 'deletePet', method: 'delete', path: '/pets/{id}' } },
    { severity: 'non-breaking', kind: 'schema.deprecated', message: 'schema deprecated' },
  ],
}

test('bumpVersion', () => {
  assert.equal(bumpVersion('0.1.0', 'major'), '1.0.0')
  assert.equal(bumpVersion('1.2.3', 'minor'), '1.3.0')
  assert.equal(bumpVersion('1.2.3', 'patch'), '1.2.4')
  assert.equal(bumpVersion('1.2.3-rc.1', 'none'), '1.2.3')
  assert.throws(() => bumpVersion('v1', 'patch'), /not a semver version/)
})

test('maxBump and bumpOfDiff', () => {
  assert.equal(maxBump('minor', 'major'), 'major')
  assert.equal(maxBump('minor', 'patch'), 'minor')
  assert.equal(bumpOfDiff({ breaking: true }), 'major')
  assert.equal(bumpOfDiff({ breaking: false, summary: { total: 3 } }), 'minor')
  assert.equal(bumpOfDiff({ breaking: false, summary: { total: 0 } }), 'patch')
  assert.equal(bumpOfDiff({ breaking: false }), 'patch')
})

test('planSdk: unchanged, first release, generator-only change', async () => {
  const fetchImpl = fakeFetch({})
  const same = await planSdk({ key: 'pets', entry: { version: '1.0.0' }, pinnedText: model('1'), candidateText: model('1'), docsUrl: DOCS, fetchImpl })
  assert.deepEqual([same.bump, same.to, same.package], ['none', '1.0.0', 'pets'])

  const first = await planSdk({ key: 'pets', entry: { version: '0.1.0', package: 'agrippa-pets' }, pinnedText: null, candidateText: model('2'), docsUrl: DOCS, fetchImpl })
  assert.deepEqual([first.bump, first.to, first.initial, first.package], ['patch', '0.1.0', true, 'agrippa-pets'])

  const regen = await planSdk({ key: 'pets', entry: { version: '1.0.0' }, pinnedText: model('1'), candidateText: model('1', { notes: ['x'] }), docsUrl: DOCS, fetchImpl })
  assert.deepEqual([regen.bump, regen.to], ['patch', '1.0.1'])
})

test('planSdk: the 2.6 diff decides (breaking → major, additive → minor, empty → patch)', async () => {
  const calls = []
  const routes = {
    '/sources/pets/diff?from=1&to=2': [200, breakingDiff],
    '/sources/pets/diff?from=1&to=3': [200, { breaking: false, summary: { total: 1, breaking: 0 }, changes: [{ severity: 'non-breaking', kind: 'operation.added', message: 'added', operation: { method: 'get', path: '/x' } }] }],
    '/sources/pets/diff?from=1&to=4': [200, { breaking: false }],
  }
  const run = to => planSdk({ key: 'pets', entry: { version: '1.4.2' }, pinnedText: model('1'), candidateText: model(to), docsUrl: DOCS, token: 't', fetchImpl: fakeFetch(routes, calls) })
  const major = await run('2')
  assert.deepEqual([major.bump, major.to, major.changes[0].operation, major.changes[1].operation], ['major', '2.0.0', 'delete /pets/{id}', null])
  assert.match(major.reason, /1 breaking, 1 other/)
  assert.equal(calls[0].auth, 'Bearer t')
  assert.deepEqual([(await run('3')).bump, (await run('3')).to], ['minor', '1.5.0'])
  const patch = await run('4')
  assert.deepEqual([patch.bump, patch.to, patch.changes], ['patch', '1.4.3', []])
})

test('planSdk: no diff (old version unknown, network error) is treated as breaking', async () => {
  const missing = await planSdk({ key: 'pets', entry: { version: '0.3.0' }, pinnedText: model('1'), candidateText: model('2'), docsUrl: DOCS, fetchImpl: fakeFetch({}) })
  assert.deepEqual([missing.bump, missing.to, missing.diffStatus], ['major', '1.0.0', 404])
  const down = await planSdk({ key: 'pets', entry: { version: '0.3.0' }, pinnedText: model('1'), candidateText: model('2'), docsUrl: DOCS, fetchImpl: fakeFetch({ '/sources/pets/diff?from=1&to=2': new Error('ECONNREFUSED') }) })
  assert.deepEqual([down.bump, down.diffStatus], ['major', 0])
  const odd = await planSdk({ key: 'pets', entry: { version: '0.3.0' }, pinnedText: model('1'), candidateText: model('2'), docsUrl: DOCS, fetchImpl: fakeFetch({ '/sources/pets/diff?from=1&to=2': Object.assign(new Error(), { message: '' }) }) })
  assert.equal(odd.diffStatus, 0)
  const thrown = await planSdk({ key: 'pets', entry: { version: '0.3.0' }, pinnedText: model('1'), candidateText: model('2'), docsUrl: DOCS, fetchImpl: async () => { throw 'boom' } }) // eslint-disable-line no-throw-literal
  assert.equal(thrown.diffStatus, 0)
})

test('planSdk: bad models', async () => {
  const args = { key: 'pets', entry: { version: '1.0.0' }, docsUrl: DOCS, fetchImpl: fakeFetch({}) }
  await assert.rejects(planSdk({ ...args, pinnedText: model('1'), candidateText: 'nope' }), /docs model: not JSON/)
  await assert.rejects(planSdk({ ...args, pinnedText: model('1'), candidateText: '{"format":"x"}' }), /not an agrippa.sdk-client-model/)
  await assert.rejects(planSdk({ ...args, pinnedText: 'null', candidateText: model('1') }), /pinned model: not an agrippa/)
  await assert.rejects(planSdk({ ...args, pinnedText: model('1'), candidateText: '{"format":"agrippa.sdk-client-model"}' }), /not an agrippa/)
})

const repo = (manifest, models = {}) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'sdk-plan-'))
  mkdirSync(path.join(dir, 'models'))
  writeFileSync(path.join(dir, 'sdks.json'), `${JSON.stringify(manifest, null, 2)}\n`)
  for (const [key, text] of Object.entries(models)) writeFileSync(path.join(dir, 'models', `${key}.json`), text)
  return dir
}

// The slice acceptance criterion: a breaking spec change produces a major
// version bump in all three SDKs. Each SDK repo runs this planner on its own
// sdks.json, so one breaking diff gives the same major in every language.
test('a breaking docs change bumps the major version in all three SDK repos', async () => {
  const routes = {
    '/sources/pets/versions/latest/sdk-model': [200, model('2.0.0')],
    '/sources/pets/diff?from=1.0.0&to=2.0.0': [200, breakingDiff],
  }
  const repos = {
    'sdk-typescript': { pets: { version: '0.4.1', package: '@agrippa-io/sdk-pets' } },
    'sdk-python': { pets: { version: '0.4.1', package: 'agrippa-pets' } },
    'sdk-java': { pets: { version: '0.4.1', package: 'io.agrippa:pets-sdk' } },
  }
  for (const [name, manifest] of Object.entries(repos)) {
    const dir = repo(manifest, { pets: model('1.0.0') })
    const out = path.join(dir, 'out')
    writeFileSync(out, '')
    const code = await main(
      ['--docs-url', DOCS, '--manifest', path.join(dir, 'sdks.json'), '--models', path.join(dir, 'models'), '--changelog', path.join(dir, 'CHANGELOG.md'), '--date', '2026-11-25', '--write'],
      { GITHUB_OUTPUT: out },
      { fetchImpl: fakeFetch(routes), log: () => {} },
    )
    assert.equal(code, 0, name)
    assert.equal(JSON.parse(readFileSync(path.join(dir, 'sdks.json'), 'utf8')).pets.version, '1.0.0', name)
    assert.match(readFileSync(out, 'utf8'), /changed=true\nbump=major/, name)
    assert.match(readFileSync(path.join(dir, 'CHANGELOG.md'), 'utf8'), new RegExp(`### \`${manifest.pets.package}\` 1.0.0 \\(major\\)`), name)
  }
})

test('plan: manifest order, errors and the overall bump', async () => {
  const dir = repo({ a: { version: '1.0.0' }, b: { version: '1.0.0' }, c: { version: '1.0.0' }, d: { version: '1.0.0' } }, { a: model('1'), b: model('1') })
  const routes = {
    '/sources/a/versions/9.9/sdk-model': [200, model('1')],
    '/sources/b/versions/9.9/sdk-model': [200, model('1', { x: 1 })],
    '/sources/c/versions/9.9/sdk-model': [200, 'garbage'],
  }
  const result = await plan({ manifest: JSON.parse(readFileSync(path.join(dir, 'sdks.json'), 'utf8')), modelsDir: path.join(dir, 'models'), docsUrl: DOCS, docsVersion: '9.9', fetchImpl: fakeFetch(routes) })
  assert.deepEqual(result.sdks.map(sdk => [sdk.key, sdk.bump]), [['a', 'none'], ['b', 'patch']])
  assert.equal(result.bump, 'patch')
  assert.equal(result.changed, true)
  assert.match(result.errors[0], /^c: docs model: not JSON/)
  assert.match(result.errors[1], /^d: HTTP 404 from http:\/\/docs.test\/docs\/v1\/sources\/d\/versions\/9.9\/sdk-model/)
})

test('changelogSection and insertSection', () => {
  assert.equal(changelogSection({ sdks: [{ bump: 'none' }] }, 'd'), '')
  const many = Array.from({ length: MAX_CHANGES + 2 }, (_, i) => ({ severity: 'non-breaking', kind: 'property.added', message: `p${i}`, operation: null }))
  const section = changelogSection({
    sdks: [
      { package: 'a', to: '2.0.0', bump: 'major', diffStatus: 200, fromDocs: '1', toDocs: '2', changes: [{ severity: 'breaking', kind: 'operation.removed', message: 'gone', operation: 'get /x' }] },
      { package: 'b', to: '1.1.0', bump: 'minor', diffStatus: 200, fromDocs: '1', toDocs: '2', changes: many },
      { package: 'c', to: '1.0.0', bump: 'major', diffStatus: 404, fromDocs: '1', toDocs: '2', changes: [] },
      { package: 'd', to: '1.0.1', bump: 'patch', fromDocs: '1', toDocs: '1', changes: [] },
      { package: 'e', to: '0.1.0', bump: 'patch', initial: true, toDocs: '3', changes: [] },
    ],
  }, '2026-11-25')
  assert.match(section, /^## 2026-11-25\n\n### `a` 2.0.0 \(major\)\n\nDocs `1` → `2`.\n\n- \*\*Breaking\*\* `operation.removed`: gone \(`get \/x`\)\n/)
  assert.match(section, /- … and 2 more\n/)
  assert.match(section, /HTTP 404\), so this release is treated as \*\*breaking\*\*/)
  assert.match(section, /Regenerated from docs `1`/)
  assert.match(section, /First release, generated from docs `3`/)

  const s = '## 2026-11-25\n\n- x\n'
  assert.equal(insertSection('# Changelog\n\n## Unreleased\n\n- wip\n\n## 2026-01-01\n\n- old\n', s), '# Changelog\n\n## Unreleased\n\n- wip\n\n## 2026-11-25\n\n- x\n\n## 2026-01-01\n\n- old\n')
  assert.equal(insertSection('# Changelog\n\n## Unreleased\n\n- wip\n', s), '# Changelog\n\n## Unreleased\n\n- wip\n\n## 2026-11-25\n\n- x\n')
  assert.equal(insertSection('# Changelog\n\n## 2026-01-01\n', s), '# Changelog\n\n## 2026-11-25\n\n- x\n\n## 2026-01-01\n')
  assert.equal(insertSection('', s), '## 2026-11-25\n\n- x\n')
  assert.equal(insertSection('# C\n', ''), '# C\n')
})

test('apply writes models, versions and the changelog', () => {
  const dir = repo({ a: { version: '1.0.0', package: 'pa' }, b: { version: '2.0.0' } })
  const result = { sdks: [{ key: 'a', package: 'pa', bump: 'minor', to: '1.1.0', fromDocs: '1', toDocs: '2', diffStatus: 200, changes: [], model: model('2') }, { key: 'b', bump: 'none', to: '2.0.0', changes: [] }] }
  const manifest = JSON.parse(readFileSync(path.join(dir, 'sdks.json'), 'utf8'))
  const changelogPath = path.join(dir, 'CHANGELOG.md')
  const next = apply({ result, manifest, manifestPath: path.join(dir, 'sdks.json'), modelsDir: path.join(dir, 'models'), changelogPath, date: '2026-11-25' })
  assert.deepEqual(next, { a: { version: '1.1.0', package: 'pa' }, b: { version: '2.0.0' } })
  assert.equal(manifest.a.version, '1.0.0') // not mutated
  assert.equal(readFileSync(path.join(dir, 'models', 'a.json'), 'utf8'), model('2'))
  assert.equal(existsSync(path.join(dir, 'models', 'b.json')), false)
  assert.match(readFileSync(changelogPath, 'utf8'), /^# Changelog\n\n## 2026-11-25\n\n### `pa` 1.1.0 \(minor\)/)
  writeFileSync(changelogPath, '# Changelog\n\n## Unreleased\n')
  apply({ result, manifest, manifestPath: path.join(dir, 'sdks.json'), modelsDir: path.join(dir, 'models'), changelogPath, date: '2026-11-26' })
  assert.match(readFileSync(changelogPath, 'utf8'), /## Unreleased\n\n## 2026-11-26/)
})

test('summary', () => {
  const text = summary({ bump: 'minor', errors: ['x: boom'], sdks: [{ package: 'a', from: '1.0.0', to: '1.1.0', bump: 'minor', reason: 'r' }, { package: 'b', from: '1.0.0', to: '1.0.0', bump: 'none', reason: 'same' }] })
  assert.match(text, /\| `a` \| 1.0.0 → 1.1.0 \| minor \| r \|/)
  assert.match(text, /\| `b` \| 1.0.0 \| none \| same \|/)
  assert.match(text, /- error: x: boom/)
})

test('parseArgs', () => {
  assert.deepEqual(parseArgs(['--docs-url', 'u', '--write', '--version', '1.2.3']), { manifest: 'sdks.json', models: 'models', changelog: 'CHANGELOG.md', version: '1.2.3', write: true, 'docs-url': 'u' })
  assert.throws(() => parseArgs(['--nope', 'x']), /unknown argument: --nope/)
  assert.throws(() => parseArgs(['stray']), /unknown argument: stray/)
  assert.throws(() => parseArgs(['--docs-url']), /--docs-url needs a value/)
  assert.throws(() => parseArgs([]), /--docs-url is required/)
})

test('main: usage, errors, dry plan, write, outputs', async () => {
  const logs = []
  const log = line => logs.push(line)
  assert.equal(await main(['--bad'], {}, { log }), 2)
  assert.match(logs.join('\n'), /usage: plan.mjs/)

  const dir = repo({ pets: { version: '1.0.0' } }, { pets: model('1') })
  const args = ['--docs-url', DOCS, '--manifest', path.join(dir, 'sdks.json'), '--models', path.join(dir, 'models'), '--changelog', path.join(dir, 'CHANGELOG.md')]

  assert.equal(await main(args, {}, { fetchImpl: fakeFetch({}), log }), 1)

  const routes = { '/sources/pets/versions/latest/sdk-model': [200, model('2')], '/sources/pets/diff?from=1&to=2': [200, { breaking: false, summary: { total: 1, breaking: 0 }, changes: [] }] }
  const calls = []
  const planOut = path.join(dir, 'plan.json')
  const stepSummary = path.join(dir, 'summary.md')
  assert.equal(await main([...args, '--plan-out', planOut], { DOCS_TOKEN: 'tok', GITHUB_STEP_SUMMARY: stepSummary }, { fetchImpl: fakeFetch(routes, calls), log }), 0)
  assert.equal(calls[0].auth, 'Bearer tok')
  const written = JSON.parse(readFileSync(planOut, 'utf8'))
  assert.equal(written.sdks[0].bump, 'minor')
  assert.equal(written.sdks[0].model, undefined)
  assert.equal(JSON.parse(readFileSync(path.join(dir, 'sdks.json'), 'utf8')).pets.version, '1.0.0') // no --write
  assert.match(readFileSync(stepSummary, 'utf8'), /Overall bump: \*\*minor\*\*/)

  const out = path.join(dir, 'out')
  assert.equal(await main([...args, '--write'], { GITHUB_OUTPUT: out }, { fetchImpl: fakeFetch(routes), log, today: new Date('2026-12-01T10:00:00Z') }), 0)
  assert.equal(JSON.parse(readFileSync(path.join(dir, 'sdks.json'), 'utf8')).pets.version, '1.1.0')
  assert.match(readFileSync(path.join(dir, 'CHANGELOG.md'), 'utf8'), /## 2026-12-01/)
  assert.equal(readFileSync(out, 'utf8'), 'changed=true\nbump=minor\nplan=\n')

  // Now pinned: nothing to release, nothing written.
  writeFileSync(out, '')
  assert.equal(await main([...args, '--write'], { GITHUB_OUTPUT: out }, { fetchImpl: fakeFetch(routes), log }), 0)
  assert.equal(readFileSync(out, 'utf8'), 'changed=false\nbump=none\nplan=\n')
  assert.ok(logs.some(line => line === 'pets: none (client model unchanged)'))
})
