import { defineCollection, z } from 'astro:content';

// Articles: long-form writing. To publish a new one, drop a Markdown file in
// src/content/articles/ with the frontmatter fields below.
const articles = defineCollection({
  type: 'content',
  schema: z.object({
    title: z.string(),
    description: z.string(),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
  }),
});

// Projects: things you're building. One Markdown file per project in
// src/content/projects/. The body is the write-up; frontmatter drives the card.
const projects = defineCollection({
  type: 'content',
  schema: z.object({
    title: z.string(),
    description: z.string(),
    status: z.enum(['active', 'shipped', 'paused', 'planned']).default('active'),
    startDate: z.coerce.date(),
    tags: z.array(z.string()).default([]),
    repo: z.string().url().optional(),
    demo: z.string().url().optional(),
    featured: z.boolean().default(false),
    order: z.number().default(0),
  }),
});

export const collections = { articles, projects };
