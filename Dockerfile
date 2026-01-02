# =====================================================
# PAYLOAD CMS v3 - PRODUCTION DOCKERFILE
# All fixes from Sliplane tutorial embedded
# =====================================================

FROM node:22.12.0-alpine AS base
WORKDIR /app

# =====================================================
# STAGE 1: DEPENDENCIES
# =====================================================
FROM base AS deps
RUN apk add --no-cache libc6-compat python3 make g++ git

# FIX #2: Pin pnpm version via corepack
RUN corepack enable pnpm && corepack prepare pnpm@9.13.2 --activate

# Create package.json with EXACT React version matching (FIX #1)
RUN cat > package.json << 'PKGEOF'
{
  "name": "payload-cms-app",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "payload": "payload",
    "generate:types": "payload generate:types",
    "generate:graphQLSchema": "payload generate:graphQLSchema"
  },
  "dependencies": {
    "@payloadcms/db-mongodb": "^3.0.0",
    "@payloadcms/next": "^3.0.0",
    "@payloadcms/richtext-lexical": "^3.0.0",
    "graphql": "^16.8.1",
    "next": "15.0.3",
    "payload": "^3.0.0",
    "react": "19.0.0",
    "react-dom": "19.0.0",
    "sharp": "^0.33.5"
  },
  "devDependencies": {
    "@types/node": "^22.10.0",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "typescript": "^5.7.0"
  }
}
PKGEOF

# Install dependencies
RUN pnpm install --frozen-lockfile || pnpm install

# =====================================================
# STAGE 2: BUILDER
# =====================================================
FROM base AS builder
RUN corepack enable pnpm && corepack prepare pnpm@9.13.2 --activate

# FIX #7: Copy package.json explicitly from deps
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/package.json ./package.json

# Create next.config.mjs with standalone output (FIX #3)
RUN cat > next.config.mjs << 'NEXTEOF'
import { withPayload } from '@payloadcms/next/withPayload'
import path from 'path'
import { fileURLToPath } from 'url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  experimental: {
    reactCompiler: false
  },
  webpack: (config) => {
    config.resolve.alias['@payload-config'] = path.resolve(__dirname, './payload.config.ts')
    return config
  }
}

export default withPayload(nextConfig)
NEXTEOF

# CACHE_BUST: 2026-01-02-17:48 - Added serverFunction prop to RootLayout
# Create tsconfig.json
RUN cat > tsconfig.json << 'TSEOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["dom", "dom.iterable", "ES2022"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "ESNext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": {
      "@/*": ["./src/*"],
      "@payload-config": ["./payload.config.ts"]
    }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
TSEOF

# Create src directory structure using sh -c to handle special characters
RUN sh -c 'mkdir -p "src/app/(payload)/admin/[[...segments]]"'
RUN sh -c 'mkdir -p "src/app/(payload)/api/[...slug]"'
RUN mkdir -p src/app/\(payload\)/api/graphql
RUN mkdir -p src/app/\(payload\)/api/graphql-playground
RUN mkdir -p src/collections

# Create payload.config.ts at root (required for @payload-config alias)
RUN cat > payload.config.ts << 'PAYLOADEOF'
import { buildConfig } from 'payload'
import { mongooseAdapter } from '@payloadcms/db-mongodb'
import { lexicalEditor } from '@payloadcms/richtext-lexical'
import path from 'path'
import { fileURLToPath } from 'url'
import sharp from 'sharp'

const filename = fileURLToPath(import.meta.url)
const dirname = path.dirname(filename)

export default buildConfig({
  admin: {
    user: 'users',
    importMap: {
      baseDir: path.resolve(dirname),
    },
  },
  collections: [
    {
      slug: 'users',
      auth: true,
      admin: { useAsTitle: 'email' },
      fields: []
    },
    {
      slug: 'media',
      upload: {
        staticDir: 'media',
        mimeTypes: ['image/*', 'application/pdf']
      },
      fields: [
        { name: 'alt', type: 'text' }
      ]
    },
    {
      slug: 'pages',
      admin: { useAsTitle: 'title' },
      fields: [
        { name: 'title', type: 'text', required: true },
        { name: 'content', type: 'richText' }
      ]
    }
  ],
  editor: lexicalEditor(),
  secret: process.env.PAYLOAD_SECRET || 'REPLACE_ME_WITH_SECRET',
  typescript: { outputFile: path.resolve(dirname, 'src/payload-types.ts') },
  db: mongooseAdapter({ url: process.env.DATABASE_URI || '' }),
  sharp,
})
PAYLOADEOF

# Create admin page
RUN cat > 'src/app/(payload)/admin/[[...segments]]/page.tsx' << 'ADMINEOF'
import type { Metadata } from 'next'
import { RootPage, generatePageMetadata } from '@payloadcms/next/views'
import { importMap } from '../importMap'
import configPromise from '@payload-config'

type Args = { params: Promise<{ segments: string[] }>; searchParams: Promise<{ [key: string]: string | string[] }> }
export const generateMetadata = ({ params, searchParams }: Args): Promise<Metadata> => generatePageMetadata({ config: configPromise, params, searchParams })
const Page = ({ params, searchParams }: Args) => RootPage({ config: configPromise, params, searchParams, importMap })
export default Page
ADMINEOF

# Create importMap
RUN cat > 'src/app/(payload)/admin/importMap.ts' << 'IMAPEOF'
export const importMap = {}
IMAPEOF

# Create API route
RUN cat > 'src/app/(payload)/api/[...slug]/route.ts' << 'APIEOF'
import { REST_DELETE, REST_GET, REST_OPTIONS, REST_PATCH, REST_POST, REST_PUT } from '@payloadcms/next/routes'
import configPromise from '@payload-config'

export const GET = REST_GET(configPromise)
export const POST = REST_POST(configPromise)
export const DELETE = REST_DELETE(configPromise)
export const PATCH = REST_PATCH(configPromise)
export const PUT = REST_PUT(configPromise)
export const OPTIONS = REST_OPTIONS(configPromise)
APIEOF

# Create GraphQL route
RUN cat > 'src/app/(payload)/api/graphql/route.ts' << 'GQLEOF'
import { GRAPHQL_POST } from '@payloadcms/next/routes'
import configPromise from '@payload-config'

export const POST = GRAPHQL_POST(configPromise)
GQLEOF

# Create GraphQL Playground route
RUN cat > 'src/app/(payload)/api/graphql-playground/route.ts' << 'GQLPEOF'
import { GRAPHQL_PLAYGROUND_GET } from '@payloadcms/next/routes'
import configPromise from '@payload-config'

export const GET = GRAPHQL_PLAYGROUND_GET(configPromise)
GQLPEOF

# Create payload layout
RUN cat > 'src/app/(payload)/layout.tsx' << 'LAYOUTEOF'
import type { Metadata } from 'next'
import { RootLayout } from '@payloadcms/next/layouts'
import { serverFunction } from '@payloadcms/next/utilities'
import configPromise from '@payload-config'
import React from 'react'
import './custom.scss'
import { importMap } from './admin/importMap'

type Args = { children: React.ReactNode }
export const metadata: Metadata = { title: 'Payload CMS' }
const Layout = ({ children }: Args) => <RootLayout config={configPromise} importMap={importMap} serverFunction={serverFunction}>{children}</RootLayout>
export default Layout
LAYOUTEOF

# Create custom.scss (empty)
RUN touch 'src/app/(payload)/custom.scss'

# Create root layout for Next.js
RUN cat > src/app/layout.tsx << 'ROOTLAYOUTEOF'
import React from 'react'

export const metadata = { title: 'Payload CMS', description: 'Payload CMS Application' }

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
ROOTLAYOUTEOF

# Create root page that redirects to admin
RUN cat > src/app/page.tsx << 'ROOTPAGEEOF'
import { redirect } from 'next/navigation'

export default function Home() {
  redirect('/admin')
}
ROOTPAGEEOF

# FIX #4: Create public folder with .gitkeep
RUN mkdir -p public && touch public/.gitkeep

# Build the application
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production
RUN pnpm build

# =====================================================
# STAGE 3: RUNNER
# =====================================================
FROM base AS runner
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# FIX #6: Create media directory with proper permissions
RUN mkdir -p media && chown -R nextjs:nodejs media

# Copy static assets
COPY --from=builder /app/public ./public

# Copy standalone build
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000

CMD ["node", "server.js"]
