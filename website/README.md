# Personal Website — Joseph Le Brun

A personal site for publishing articles and showing off projects. Built with
[Astro](https://astro.build) — articles and projects are plain Markdown files,
and the site builds to static HTML that can be hosted anywhere (AWS S3 +
CloudFront, GitHub Pages, Netlify, Vercel, …).

## Quick start

```bash
cd website
npm install        # first time only
npm run dev        # local dev server at http://localhost:4321
npm run build      # production build into dist/
npm run preview    # preview the production build locally
```

## Publishing a new article

Add a Markdown file to `src/content/articles/`. The filename becomes the URL
slug (`my-post.md` → `/articles/my-post/`). Start with this frontmatter:

```markdown
---
title: Your Article Title
description: One or two sentences shown in listings and link previews.
pubDate: 2026-06-16
tags: ['AI Evaluation', 'Career']
draft: false          # set true to keep it out of the build while you write
---

Your article body in Markdown...
```

That's it — rebuild (or keep `npm run dev` running) and the article appears on
the homepage, the `/articles` index, and the RSS feed automatically, sorted by
date.

## Adding a project

Add a Markdown file to `src/content/projects/`. The body is the write-up; the
frontmatter drives the project card:

```markdown
---
title: Project Name
description: What it is, in a sentence.
status: active        # active | shipped | paused | planned
startDate: 2026-06-01
tags: ['AWS', 'Python']
repo: https://github.com/AcroIsTrash/your-repo   # optional
demo: https://your-demo-url.com                  # optional
order: 3              # lower numbers sort first on the page
---

The project write-up in Markdown...
```

## Structure

```
website/
├── src/
│   ├── content/
│   │   ├── articles/        # one Markdown file per article
│   │   ├── projects/        # one Markdown file per project
│   │   └── config.ts        # frontmatter schema (validated at build time)
│   ├── layouts/             # page + article shells
│   ├── components/          # Header, Footer
│   ├── pages/               # routes (home, about, articles, projects, rss)
│   └── styles/global.css    # design system (light + dark, system preference)
└── public/                  # static assets (favicon, images)
```

## Deploying

`npm run build` outputs a fully static site to `dist/`. To deploy:

- **AWS S3 + CloudFront** — sync `dist/` to a bucket configured for static
  hosting and put CloudFront in front of it. This fits naturally with the
  Terraform/AWS work in the parent repo.
- **GitHub Pages / Netlify / Vercel** — point the build command at
  `npm run build` and the publish directory at `website/dist`.

Before going live, set your real domain in `astro.config.mjs` (`site:`) so RSS
and absolute URLs are correct.
