import { existsSync, mkdirSync, renameSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { env } from '../env'

/**
 * Warsha's own data: what you pin, note and plan. SQLite through Node's built-in driver, in one
 * file (gitignored). Everything else in the app is read live from GitHub and Linear.
 */

/** Each entry runs once, in order; the database remembers how far it got (user_version). */
const MIGRATIONS = [
  `create table pins (
     ref text primary key,
     title text not null,
     url text,
     pinned_at text not null
   );
   create table notes (
     ref text primary key,
     body text not null,
     updated_at text not null
   );
   create table todos (
     id integer primary key autoincrement,
     text text not null,
     ref text,
     due_date text,
     done_at text,
     created_at text not null
   );
   create table settings (
     key text primary key,
     value text not null
   );`,
  // Parked: tickets and PRs set aside on purpose, so they stop asking for attention.
  `create table parked (
     ref text primary key,
     title text not null,
     url text,
     reason text,
     until text,
     parked_at text not null
   );`,
  // Google Calendar meetings as last seen, so the next sync can tell what moved or disappeared.
  `create table meetings (
     id text primary key,
     title text not null,
     start text not null,
     end text not null,
     all_day integer not null,
     join_url text,
     html_url text,
     location text,
     declined integer not null default 0,
     previous_start text,
     previous_end text,
     rescheduled_at text,
     deleted_at text,
     first_seen_at text not null,
     updated_at text not null
   );`,
]

/** Warsha was called Workbench: its data/workbench.sqlite (with -wal and -shm) becomes warsha.sqlite. */
function moveFromWorkbench(path: string) {
  const old = resolve(dirname(path), 'workbench.sqlite')
  if (!path.endsWith('/warsha.sqlite') || existsSync(path) || !existsSync(old)) return
  for (const suffix of ['', '-wal', '-shm']) if (existsSync(old + suffix)) renameSync(old + suffix, path + suffix)
}

function open(): DatabaseSync {
  const path = resolve(env.dbPath)
  mkdirSync(dirname(path), { recursive: true })
  moveFromWorkbench(path)
  const db = new DatabaseSync(path)
  db.exec('pragma journal_mode = wal; pragma foreign_keys = on;')
  const { user_version: version } = db.prepare('pragma user_version').get() as { user_version: number }
  for (let i = version; i < MIGRATIONS.length; i++) {
    db.exec('begin')
    try {
      db.exec(MIGRATIONS[i]!)
      db.exec(`pragma user_version = ${i + 1}`)
      db.exec('commit')
    } catch (error) {
      db.exec('rollback')
      throw error
    }
  }
  console.log(`[store] ${path} (schema v${MIGRATIONS.length})`)
  return db
}

export const db = open()
