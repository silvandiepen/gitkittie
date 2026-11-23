---
title: From a screenshot to a task, in the share sheet
description: Most of my bug reports start as a screenshot I forget about. Now I share it to GitKittie Tasks, mark what is wrong, and a task is drafted from my marks — on the device, or by a model that can see the picture if I give it a key.
date: 2026-11-23
app: tasks
shot: /screenshots/tasks/iphone-board-dark.webp
shotAlt: A GitKittie Tasks board on iPhone
related: reviewing-agent-work-from-your-phone, agents-work-the-board, one-task-one-file
---

I test my apps on the phone, in between other things. I see something off, take a
screenshot, and mean to file it later. Later, the camera roll has forty screenshots and
no memory of what was wrong with any of them.

So the screenshot now goes straight to the board, while I still know.

## The flow

From Photos, or straight from the screenshot preview, tap **Share** and choose **Tasks**.

1. **Pick the project.** Any board you have in Tasks.
2. **New task or existing task.** A new task, in the lane you choose — or add the
   screenshot to a task that is already there, when it is more of the same.
3. **Mark what is wrong.** Draw a box around the part that is off and write what you
   mean next to it. You can mark several parts; each mark gets a number.
4. **Add pointers if you like.** "This only happens in dark mode" goes in the notes.
5. **Check the draft and save.** The title, description, type and priority are filled in
   for you. Change any of them, then save.

The screenshot is attached to the task, and your marks are written into the task as a
numbered **Annotations** list, matching the numbers on the image. Whoever picks the task
up — me, or [an agent](/blog/agents-work-the-board) — gets the picture and exactly what
the marks meant.

![A task in GitKittie Tasks on iPad, with its details and notes](/screenshots/tasks/ipad-task-light.webp)

## Who writes the draft

This part is worth being precise about, because it differs by setup:

- **On the device.** With Apple Intelligence available and no key set, the draft is made
  on the phone, from your comments and the text read out of the screenshot. The
  on-device model cannot see the picture itself, and the sheet says so. Your marks and
  pointers matter most here.
- **With your own key.** Add an AI provider key in Tasks (account menu, AI Settings) and
  that model looks at the image itself, so it can describe what it sees.
- **Neither.** Nothing drafts. The first comment on a mark becomes the title, and you
  fill in the rest.

Either way the draft is a suggestion. Nothing is saved until you save it.

## Why the share sheet

Because that is where the screenshot already is. Opening the app, finding the board,
making a task and attaching an image is four steps too many when you are in the middle of
testing something else. From the share sheet it is: mark, comment, save.

And because a task is [a markdown file in your repository](/blog/one-task-one-file), the
screenshot ends up next to the code it is about, not in a tracker you have to keep in step
with it.

---

The opposite direction — an agent asking you to judge what it made — is
[reviewing what an agent made, from your phone](/blog/reviewing-agent-work-from-your-phone).
