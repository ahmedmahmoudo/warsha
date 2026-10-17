import type { Meeting } from '../../shared/calendar'
import type { Note, Parked, Pin, Todo } from '../../shared/store'
import type { GoogleEvent } from '../integrations/google'
import { db } from './db'

/** All reads and writes of Workbench's own data go through here, so the storage can change later. */

type PinRow = { ref: string; title: string; url: string | null; pinned_at: string }
type NoteRow = { ref: string; body: string; updated_at: string }
type TodoRow = { id: number; text: string; ref: string | null; due_date: string | null; done_at: string | null; created_at: string }

type ParkedRow = { ref: string; title: string; url: string | null; reason: string | null; until: string | null; parked_at: string }
const toParked = (row: ParkedRow): Parked => ({
  ref: row.ref,
  title: row.title,
  url: row.url,
  reason: row.reason,
  until: row.until,
  parkedAt: row.parked_at,
})

const toPin = (row: PinRow): Pin => ({ ref: row.ref, title: row.title, url: row.url, pinnedAt: row.pinned_at })
const toNote = (row: NoteRow): Note => ({ ref: row.ref, body: row.body, updatedAt: row.updated_at })
const toTodo = (row: TodoRow): Todo => ({
  id: row.id,
  text: row.text,
  ref: row.ref,
  dueDate: row.due_date,
  doneAt: row.done_at,
  createdAt: row.created_at,
})

const now = () => new Date().toISOString()

export const pins = {
  list: (): Pin[] => (db.prepare('select * from pins order by pinned_at').all() as PinRow[]).map(toPin),
  add(pin: { ref: string; title: string; url: string | null }): Pin {
    db.prepare(
      'insert into pins (ref, title, url, pinned_at) values (?, ?, ?, ?) on conflict(ref) do update set title = excluded.title, url = excluded.url',
    ).run(pin.ref, pin.title, pin.url, now())
    return toPin(db.prepare('select * from pins where ref = ?').get(pin.ref) as PinRow)
  },
  remove: (ref: string) => db.prepare('delete from pins where ref = ?').run(ref).changes > 0,
}

export const notes = {
  list: (): Note[] => (db.prepare('select * from notes order by updated_at desc').all() as NoteRow[]).map(toNote),
  /** An empty body deletes the note. */
  set(ref: string, body: string): Note | null {
    if (!body.trim()) {
      db.prepare('delete from notes where ref = ?').run(ref)
      return null
    }
    db.prepare(
      'insert into notes (ref, body, updated_at) values (?, ?, ?) on conflict(ref) do update set body = excluded.body, updated_at = excluded.updated_at',
    ).run(ref, body.trim(), now())
    return toNote(db.prepare('select * from notes where ref = ?').get(ref) as NoteRow)
  },
}

export const todos = {
  /** Open ones first (dated soonest first), then the last week's done ones. */
  list: (): Todo[] =>
    (
      db
        .prepare(
          `select * from todos
           where done_at is null or done_at >= ?
           order by done_at is not null, coalesce(due_date, '9999') , created_at`,
        )
        .all(new Date(Date.now() - 7 * 86_400_000).toISOString()) as TodoRow[]
    ).map(toTodo),
  add(todo: { text: string; ref: string | null; dueDate: string | null }): Todo {
    const { lastInsertRowid } = db
      .prepare('insert into todos (text, ref, due_date, created_at) values (?, ?, ?, ?)')
      .run(todo.text.trim(), todo.ref, todo.dueDate, now())
    return toTodo(db.prepare('select * from todos where id = ?').get(lastInsertRowid) as TodoRow)
  },
  update(id: number, change: { text?: string; done?: boolean; dueDate?: string | null }): Todo | null {
    const existing = db.prepare('select * from todos where id = ?').get(id) as TodoRow | undefined
    if (!existing) return null
    db.prepare('update todos set text = ?, due_date = ?, done_at = ? where id = ?').run(
      change.text?.trim() || existing.text,
      change.dueDate === undefined ? existing.due_date : change.dueDate,
      change.done === undefined ? existing.done_at : change.done ? (existing.done_at ?? now()) : null,
      id,
    )
    return toTodo(db.prepare('select * from todos where id = ?').get(id) as TodoRow)
  },
  remove: (id: number) => db.prepare('delete from todos where id = ?').run(id).changes > 0,
}

export const parked = {
  list: (): Parked[] => (db.prepare('select * from parked order by parked_at desc').all() as ParkedRow[]).map(toParked),
  /** Parking again updates the reason and date. */
  add(item: { ref: string; title: string; url: string | null; reason: string | null; until: string | null }): Parked {
    db.prepare(
      `insert into parked (ref, title, url, reason, until, parked_at) values (?, ?, ?, ?, ?, ?)
       on conflict(ref) do update set title = excluded.title, url = excluded.url, reason = excluded.reason, until = excluded.until`,
    ).run(item.ref, item.title, item.url, item.reason, item.until, now())
    return toParked(db.prepare('select * from parked where ref = ?').get(item.ref) as ParkedRow)
  },
  remove: (ref: string) => db.prepare('delete from parked where ref = ?').run(ref).changes > 0,
}

export const settings = {
  get: (key: string): string | null => (db.prepare('select value from settings where key = ?').get(key) as { value: string } | undefined)?.value ?? null,
  set: (key: string, value: string) =>
    db.prepare('insert into settings (key, value) values (?, ?) on conflict(key) do update set value = excluded.value').run(key, value),
  remove: (key: string) => db.prepare('delete from settings where key = ?').run(key),
}

type MeetingRow = {
  id: string
  title: string
  start: string
  end: string
  all_day: number
  join_url: string | null
  html_url: string | null
  location: string | null
  declined: number
  previous_start: string | null
  previous_end: string | null
  rescheduled_at: string | null
  deleted_at: string | null
  first_seen_at: string
  updated_at: string
}

const toMeeting = (row: MeetingRow): Meeting => ({
  id: row.id,
  title: row.title,
  start: row.start,
  end: row.end,
  allDay: row.all_day === 1,
  joinUrl: row.join_url,
  htmlUrl: row.html_url,
  location: row.location,
  declined: row.declined === 1,
  change: row.deleted_at
    ? { kind: 'deleted', at: row.deleted_at }
    : row.previous_start && row.previous_end && row.rescheduled_at
      ? { kind: 'rescheduled', previousStart: row.previous_start, previousEnd: row.previous_end, at: row.rescheduled_at }
      : null,
})

export const meetings = {
  list: (): Meeting[] => (db.prepare('select * from meetings order by start').all() as MeetingRow[]).map(toMeeting),
  get: (id: string): Meeting | null => {
    const row = db.prepare('select * from meetings where id = ?').get(id) as MeetingRow | undefined
    return row ? toMeeting(row) : null
  },
  /**
   * Saves what Google returned. A new time on a saved meeting marks it rescheduled, remembering the
   * time you knew; moving back to that time clears the mark. Reappearing undoes a deletion.
   */
  save(event: GoogleEvent, at: string) {
    const row = db.prepare('select * from meetings where id = ?').get(event.id) as MeetingRow | undefined
    if (!row) {
      db.prepare(
        `insert into meetings (id, title, start, end, all_day, join_url, html_url, location, declined, first_seen_at, updated_at)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).run(event.id, event.title, event.start, event.end, Number(event.allDay), event.joinUrl, event.htmlUrl, event.location, Number(event.response === 'declined'), at, at)
      return
    }
    let { previous_start: previousStart, previous_end: previousEnd, rescheduled_at: rescheduledAt } = row
    if (row.start !== event.start || row.end !== event.end) {
      if (!previousStart) [previousStart, previousEnd, rescheduledAt] = [row.start, row.end, at]
      else if (previousStart === event.start && previousEnd === event.end) [previousStart, previousEnd, rescheduledAt] = [null, null, null]
      else rescheduledAt = at
    }
    db.prepare(
      `update meetings set title = ?, start = ?, end = ?, all_day = ?, join_url = ?, html_url = ?, location = ?, declined = ?,
         previous_start = ?, previous_end = ?, rescheduled_at = ?, deleted_at = null, updated_at = ?
       where id = ?`,
    ).run(
      event.title, event.start, event.end, Number(event.allDay), event.joinUrl, event.htmlUrl, event.location, Number(event.response === 'declined'),
      previousStart, previousEnd, rescheduledAt, at, event.id,
    )
  },
  /** Marks a saved meeting deleted, keeping when that was first noticed. */
  markDeleted: (id: string, at: string) => db.prepare('update meetings set deleted_at = coalesce(deleted_at, ?) where id = ?').run(at, id),
  remove: (id: string) => db.prepare('delete from meetings where id = ?').run(id).changes > 0,
  /** Forgets every meeting, for when the Google account is disconnected. */
  clear: () => db.prepare('delete from meetings').run(),
  /** Hides a reschedule notice: the new time becomes the one you know. */
  acknowledge: (id: string) =>
    db.prepare('update meetings set previous_start = null, previous_end = null, rescheduled_at = null where id = ?').run(id).changes > 0,
}
