import fs from 'node:fs'
import path from 'node:path'
import type { Plugin, ResolvedConfig } from 'vite'
import { missingPostFields, parseFrontmatter } from '../src/lib/frontmatter'
import { articleJsonLd, metaTags, shareImagePath, staticFileFor, staticPages, type HeadMeta } from '../src/lib/seo'

/**
 * Writes a static HTML file for every route and every article, each with its own title,
 * description, canonical URL, Open Graph and Twitter tags (and article data for posts), and
 * writes the sitemap from the same list.
 *
 * The site is a single-page app: in the browser `usePageMeta` sets the head. Link previews
 * in Slack, iMessage, LinkedIn or X do not run JavaScript, though, so without these files
 * every shared link showed the home page. Each file is the built `index.html` with its head
 * replaced — the app still boots and takes over as before.
 *
 * The build fails when an article lacks a required field or a page lacks its share card in
 * `public/og/` (made by `npm run og`), so nothing ships that shares without a picture.
 */
export function staticPagesPlugin(options: { origin: string; locale?: string }): Plugin {
  const locale = options.locale ?? 'en'
  let config: ResolvedConfig

  return {
    name: 'gitkittie-static-pages',
    apply: 'build',
    configResolved(resolved) {
      config = resolved
    },
    closeBundle() {
      const root = config.root
      const outDir = path.resolve(root, config.build.outDir)
      const template = fs.readFileSync(path.join(outDir, 'index.html'), 'utf8')
      const entries: Array<{ path: string; head: HeadMeta; changefreq: string; priority: number; lastmod?: string }> = []

      for (const page of staticPages) {
        const content = JSON.parse(fs.readFileSync(path.join(root, `src/i18n/locales/${locale}/${page.content}.json`), 'utf8'))
        const meta = (page.key ? content[page.key] : content).meta as { title: string; description: string } | undefined
        if (!meta?.title || !meta.description) throw new Error(`${page.content}.json has no meta title and description for ${page.path}`)
        entries.push({
          path: page.path,
          head: head(page.path, meta.title, meta.description, page.shotAlt ?? meta.title, 'website'),
          changefreq: page.changefreq,
          priority: page.priority,
        })
      }

      const postsDir = path.join(root, `src/i18n/posts/${locale}`)
      for (const file of fs.readdirSync(postsDir).filter((name) => name.endsWith('.md')).sort()) {
        const slug = file.replace(/\.md$/, '')
        const { fields } = parseFrontmatter(fs.readFileSync(path.join(postsDir, file), 'utf8'))
        const missing = missingPostFields(fields)
        if (missing.length) throw new Error(`Article ${slug} is missing ${missing.join(', ')} in its frontmatter`)
        const route = `/blog/${slug}`
        entries.push({
          path: route,
          head: { ...head(route, `${fields.title} — GitKittie`, fields.description, fields.shotAlt, 'article', fields.date), headline: fields.title },
          changefreq: 'monthly',
          priority: 0.7,
          lastmod: fields.date,
        })
      }

      for (const entry of entries) {
        const card = path.join(root, 'public', shareImagePath(entry.path))
        if (!fs.existsSync(card)) {
          throw new Error(`${entry.path} has no share card at public${shareImagePath(entry.path)} — run \`npm run og\` in apps/website`)
        }
        const file = path.join(outDir, staticFileFor(entry.path))
        fs.mkdirSync(path.dirname(file), { recursive: true })
        fs.writeFileSync(file, withHead(template, entry.head))
      }

      fs.writeFileSync(path.join(outDir, 'sitemap.xml'), sitemap(entries))
    },
  }

  function head(route: string, title: string, description: string, imageAlt: string, type: HeadMeta['type'], published?: string): HeadMeta {
    return {
      title,
      description,
      url: `${options.origin}${route === '/' ? '' : route}`,
      image: `${options.origin}${shareImagePath(route)}`,
      imageAlt,
      type,
      published,
    }
  }

  function withHead(html: string, meta: HeadMeta): string {
    const tags = [
      `<link rel="canonical" href="${attr(meta.url)}" />`,
      ...metaTags(meta).map(([kind, key, content]) => `<meta ${kind}="${key}" content="${attr(content)}" />`),
    ]
    if (meta.type === 'article') {
      // `<` escaped so a title can never close the script element.
      tags.push(`<script type="application/ld+json">${JSON.stringify(articleJsonLd(meta, options.origin)).replace(/</g, '\\u003c')}</script>`)
    }
    return html
      .replace(/<title>[\s\S]*?<\/title>/, `<title>${text(meta.title)}</title>`)
      .replace(/\s*<meta name="description"[^>]*>/, '')
      .replace('</head>', `    ${tags.join('\n    ')}\n  </head>`)
  }

  function sitemap(entries: Array<{ path: string; changefreq: string; priority: number; lastmod?: string }>): string {
    const urls = entries.map((entry) => {
      const loc = `${options.origin}${entry.path === '/' ? '/' : entry.path}`
      const lastmod = entry.lastmod ? `<lastmod>${entry.lastmod}</lastmod>` : ''
      return `  <url><loc>${text(loc)}</loc>${lastmod}<changefreq>${entry.changefreq}</changefreq><priority>${entry.priority.toFixed(1)}</priority></url>`
    })
    return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join('\n')}\n</urlset>\n`
  }
}

function text(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function attr(value: string): string {
  return text(value).replace(/"/g, '&quot;')
}
