
---

# advanced-ssr


---
id: advanced-ssr
title: Advanced Server Rendering
---

Welcome to the Advanced Server Rendering guide, where you will learn all about using React Query with streaming, Server Components and the Next.js app router.

You might want to read the [Server Rendering & Hydration guide](../ssr) before this one as it teaches the basics for using React Query with SSR, and [Performance & Request Waterfalls](../request-waterfalls) as well as [Prefetching & Router Integration](../prefetching) also contains valuable background.

Before we start, let's note that while the `initialData` approach outlined in the SSR guide also works with Server Components, we'll focus this guide on the hydration APIs.

## Server Components & Next.js app router

We won't cover Server Components in depth here, but the short version is that they are components that are guaranteed to _only_ run on the server, both for the initial page view and **also on page transitions**. This is similar to how Next.js `getServerSideProps`/`getStaticProps` and Remix `loader` works, as these also always run on the server but while those can only return data, Server Components can do a lot more. The data part is central to React Query however, so let's focus on that.

How do we take what we learned in the Server Rendering guide about [passing data prefetched in framework loaders to the app](../ssr#using-the-hydration-apis) and apply that to Server Components and the Next.js app router? The best way to start thinking about this is to consider Server Components as "just" another framework loader.

### A quick note on terminology

So far in these guides, we've been talking about the _server_ and the _client_. It's important to note that confusingly enough this does not match 1-1 with _Server Components_ and _Client Components_. Server Components are guaranteed to only run on the server, but Client Components can actually run in both places. The reason for this is that they can also render during the initial _server rendering_ pass.

One way to think of this is that even though Server Components also _render_, they happen during a "loader phase" (always happens on the server), while Client Components run during the "application phase". That application can run both on the server during SSR, and in for example a browser. Where exactly that application runs and if it runs during SSR or not might differ between frameworks.

### Initial setup

The first step of any React Query setup is always to create a `queryClient` and wrap your application in a `QueryClientProvider`. With Server Components, this looks mostly the same across frameworks, one difference being the filename conventions:

```tsx
// In Next.js, this file would be called: app/providers.tsx
'use client'

// Since QueryClientProvider relies on useContext under the hood, we have to put 'use client' on top
import {
  isServer,
  QueryClient,
  QueryClientProvider,
} from '@tanstack/react-query'

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        // With SSR, we usually want to set some default staleTime
        // above 0 to avoid refetching immediately on the client
        staleTime: 60 * 1000,
      },
    },
  })
}

let browserQueryClient: QueryClient | undefined = undefined

function getQueryClient() {
  if (isServer) {
    // Server: always make a new query client
    return makeQueryClient()
  } else {
    // Browser: make a new query client if we don't already have one
    // This is very important, so we don't re-make a new client if React
    // suspends during the initial render. This may not be needed if we
    // have a suspense boundary BELOW the creation of the query client
    if (!browserQueryClient) browserQueryClient = makeQueryClient()
    return browserQueryClient
  }
}

export default function Providers({ children }: { children: React.ReactNode }) {
  // NOTE: Avoid useState when initializing the query client if you don't
  //       have a suspense boundary between this and the code that may
  //       suspend because React will throw away the client on the initial
  //       render if it suspends and there is no boundary
  const queryClient = getQueryClient()

  return (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  )
}
```

```tsx
// In Next.js, this file would be called: app/layout.tsx
import Providers from './providers'

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <head />
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
```

This part is pretty similar to what we did in the SSR guide, we just need to split things up into two different files.

### Prefetching and de/hydrating data

Let's next look at how to actually prefetch data and dehydrate and hydrate it. This is what it looked like using the **Next.js pages router**:

```tsx
// pages/posts.tsx
import {
  dehydrate,
  HydrationBoundary,
  QueryClient,
  useQuery,
} from '@tanstack/react-query'

// This could also be getServerSideProps
export async function getStaticProps() {
  const queryClient = new QueryClient()

  await queryClient.prefetchQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
  })

  return {
    props: {
      dehydratedState: dehydrate(queryClient),
    },
  }
}

function Posts() {
  // This useQuery could just as well happen in some deeper child to
  // the <PostsRoute>, data will be available immediately either way
  //
  // Note that we are using useQuery here instead of useSuspenseQuery.
  // Because this data has already been prefetched, there is no need to
  // ever suspend in the component itself. If we forget or remove the
  // prefetch, this will instead fetch the data on the client, while
  // using useSuspenseQuery would have had worse side effects.
  const { data } = useQuery({ queryKey: ['posts'], queryFn: getPosts })

  // This query was not prefetched on the server and will not start
  // fetching until on the client, both patterns are fine to mix
  const { data: commentsData } = useQuery({
    queryKey: ['posts-comments'],
    queryFn: getComments,
  })

  // ...
}

export default function PostsRoute({ dehydratedState }) {
  return (
    <HydrationBoundary state={dehydratedState}>
      <Posts />
    </HydrationBoundary>
  )
}
```

Converting this to the app router actually looks pretty similar, we just need to move things around a bit. First, we'll create a Server Component to do the prefetching part:

```tsx
// app/posts/page.tsx
import {
  dehydrate,
  HydrationBoundary,
  QueryClient,
} from '@tanstack/react-query'
import Posts from './posts'

export default async function PostsPage() {
  const queryClient = new QueryClient()

  await queryClient.prefetchQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
  })

  return (
    // Neat! Serialization is now as easy as passing props.
    // HydrationBoundary is a Client Component, so hydration will happen there.
    <HydrationBoundary state={dehydrate(queryClient)}>
      <Posts />
    </HydrationBoundary>
  )
}
```

Next, we'll look at what the Client Component part looks like:

```tsx
// app/posts/posts.tsx
'use client'

export default function Posts() {
  // This useQuery could just as well happen in some deeper
  // child to <Posts>, data will be available immediately either way
  const { data } = useQuery({
    queryKey: ['posts'],
    queryFn: () => getPosts(),
  })

  // This query was not prefetched on the server and will not start
  // fetching until on the client, both patterns are fine to mix.
  const { data: commentsData } = useQuery({
    queryKey: ['posts-comments'],
    queryFn: getComments,
  })

  // ...
}
```

One neat thing about the examples above is that the only thing that is Next.js-specific here are the file names, everything else would look the same in any other framework that supports Server Components.

In the SSR guide, we noted that you could get rid of the boilerplate of having `<HydrationBoundary>` in every route. This is not possible with Server Components.

> NOTE: If you encounter a type error while using async Server Components with TypeScript versions lower than `5.1.3` and `@types/react` versions lower than `18.2.8`, it is recommended to update to the latest versions of both. Alternatively, you can use the temporary workaround of adding `{/* @ts-expect-error Server Component */}` when calling this component inside another. For more information, see [Async Server Component TypeScript Error](https://nextjs.org/docs/app/building-your-application/configuring/typescript#async-server-component-typescript-error) in the Next.js 13 docs.

> NOTE: If you encounter an error `Only plain objects, and a few built-ins, can be passed to Server Actions. Classes or null prototypes are not supported.` make sure that you're **not** passing to queryFn a function reference, instead call the function because queryFn args has a bunch of properties and not all of it would be serializable. see [Server Action only works when queryFn isn't a reference](https://github.com/TanStack/query/issues/6264).

### Nesting Server Components

A nice thing about Server Components is that they can be nested and exist on many levels in the React tree, making it possible to prefetch data closer to where it's actually used instead of only at the top of the application (just like Remix loaders). This can be as simple as a Server Component rendering another Server Component (we'll leave the Client Components out in this example for brevity):

```tsx
// app/posts/page.tsx
import {
  dehydrate,
  HydrationBoundary,
  QueryClient,
} from '@tanstack/react-query'
import Posts from './posts'
import CommentsServerComponent from './comments-server'

export default async function PostsPage() {
  const queryClient = new QueryClient()

  await queryClient.prefetchQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <Posts />
      <CommentsServerComponent />
    </HydrationBoundary>
  )
}

// app/posts/comments-server.tsx
import {
  dehydrate,
  HydrationBoundary,
  QueryClient,
} from '@tanstack/react-query'
import Comments from './comments'

export default async function CommentsServerComponent() {
  const queryClient = new QueryClient()

  await queryClient.prefetchQuery({
    queryKey: ['posts-comments'],
    queryFn: getComments,
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <Comments />
    </HydrationBoundary>
  )
}
```

As you can see, it's perfectly fine to use `<HydrationBoundary>` in multiple places, and create and dehydrate multiple `queryClient` for prefetching.

Note that because we are awaiting `getPosts` before rendering `CommentsServerComponent` this would lead to a server side waterfall:

```
1. |> getPosts()
2.   |> getComments()
```

If the server latency to the data is low, this might not be a huge issue, but is still worth pointing out.

In Next.js, besides prefetching data in `page.tsx`, you can also do it in `layout.tsx`, and in [parallel routes](https://nextjs.org/docs/app/building-your-application/routing/parallel-routes). Because these are all part of the routing, Next.js knows how to fetch them all in parallel. So if `CommentsServerComponent` above was instead expressed as a parallel route, the waterfall would be flattened automatically.

As more frameworks start supporting Server Components, they might have other routing conventions. Read your framework docs for details.

### Alternative: Use a single `queryClient` for prefetching

In the example above, we create a new `queryClient` for each Server Component that fetches data. This is the recommended approach, but if you want to, you can alternatively create a single one that is reused across all Server Components:

```tsx
// app/getQueryClient.tsx
import { QueryClient } from '@tanstack/react-query'
import { cache } from 'react'

// cache() is scoped per request, so we don't leak data between requests
const getQueryClient = cache(() => new QueryClient())
export default getQueryClient
```

The benefit of this is that you can call `getQueryClient()` to get a hold of this client anywhere that gets called from a Server Component, including utility functions. The downside is that every time you call `dehydrate(getQueryClient())`, you serialize _the entire_ `queryClient`, including queries that have already been serialized before and are unrelated to the current Server Component which is unnecessary overhead.

Next.js already dedupes requests that utilize `fetch()`, but if you are using something else in your `queryFn`, or if you use a framework that does _not_ dedupe these requests automatically, using a single `queryClient` as described above might make sense, despite the duplicated serialization.

> As a future improvement, we might look into creating a `dehydrateNew()` function (name pending) that only dehydrate queries that are _new_ since the last call to `dehydrateNew()`. Feel free to get in touch if this sounds interesting and like something you want to help out with!

### Data ownership and revalidation

With Server Components, it's important to think about data ownership and revalidation. To explain why, let's look at a modified example from above:

```tsx
// app/posts/page.tsx
import {
  dehydrate,
  HydrationBoundary,
  QueryClient,
} from '@tanstack/react-query'
import Posts from './posts'

export default async function PostsPage() {
  const queryClient = new QueryClient()

  // Note we are now using fetchQuery()
  const posts = await queryClient.fetchQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      {/* This is the new part */}
      <div>Nr of posts: {posts.length}</div>
      <Posts />
    </HydrationBoundary>
  )
}
```

We are now rendering data from the `getPosts` query both in a Server Component and in a Client Component. This will be fine for the initial page render, but what happens when the query revalidates on the client for some reason when `staleTime` has been passed?

React Query has no idea of how to _revalidate the Server Component_, so if it refetches the data on the client, causing React to rerender the list of posts, the `Nr of posts: {posts.length}` will end up out of sync.

This is fine if you set `staleTime: Infinity`, so that React Query never revalidates, but this is probably not what you want if you are using React Query in the first place.

Using React Query with Server Components makes most sense if:

- You have an app using React Query and want to migrate to Server Components without rewriting all the data fetching
- You want a familiar programming paradigm, but want to still sprinkle in the benefits of Server Components where it makes most sense
- You have some use case that React Query covers, but that your framework of choice does not cover

It's hard to give general advice on when it makes sense to pair React Query with Server Components and not. **If you are just starting out with a new Server Components app, we suggest you start out with any tools for data fetching your framework provides you with and avoid bringing in React Query until you actually need it.** This might be never, and that's fine, use the right tool for the job!

If you do use it, a good rule of thumb is to avoid `queryClient.fetchQuery` unless you need to catch errors. If you do use it, don't render its result on the server or pass the result to another component, even a Client Component one.

From the React Query perspective, treat Server Components as a place to prefetch data, nothing more.

Of course, it's fine to have Server Components own some data, and Client Components own other, just make sure those two realities don't get out of sync.

## Streaming with Server Components

The Next.js app router automatically streams any part of the application that is ready to be displayed to the browser as soon as possible, so finished content can be displayed immediately without waiting for still pending content. It does this along `<Suspense>` boundary lines. Note that if you create a file `loading.tsx`, this automatically creates a `<Suspense>` boundary behind the scenes.

With the prefetching patterns described above, React Query is perfectly compatible with this form of streaming. As the data for each Suspense boundary resolves, Next.js can render and stream the finished content to the browser. This works even if you are using `useQuery` as outlined above because the suspending actually happens when you `await` the prefetch.

As of React Query v5.40.0, you don't have to `await` all prefetches for this to work, as `pending` Queries can also be dehydrated and sent to the client. This lets you kick off prefetches as early as possible without letting them block an entire Suspense boundary, and streams the _data_ to the client as the query finishes. This can be useful for example if you want to prefetch some content that is only visible after some user interaction, or say if you want to `await` and render the first page of an infinite query, but start prefetching page 2 without blocking rendering.

To make this work, we have to instruct the `queryClient` to also `dehydrate` pending Queries. We can do this globally, or by passing that option directly to `dehydrate`.

We will also need to move the `getQueryClient()` function out of our `app/providers.tsx` file as we want to use it in our server component and our client provider.

```tsx
// app/get-query-client.ts
import {
  isServer,
  QueryClient,
  defaultShouldDehydrateQuery,
} from '@tanstack/react-query'

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 60 * 1000,
      },
      dehydrate: {
        // include pending queries in dehydration
        shouldDehydrateQuery: (query) =>
          defaultShouldDehydrateQuery(query) ||
          query.state.status === 'pending',
      },
    },
  })
}

let browserQueryClient: QueryClient | undefined = undefined

export function getQueryClient() {
  if (isServer) {
    // Server: always make a new query client
    return makeQueryClient()
  } else {
    // Browser: make a new query client if we don't already have one
    // This is very important, so we don't re-make a new client if React
    // suspends during the initial render. This may not be needed if we
    // have a suspense boundary BELOW the creation of the query client
    if (!browserQueryClient) browserQueryClient = makeQueryClient()
    return browserQueryClient
  }
}
```

> Note: This works in NextJs and Server Components because React can serialize Promises over the wire when you pass them down to Client Components.

Then, all we need to do is provide a `HydrationBoundary`, but we don't need to `await` prefetches anymore:

```tsx
// app/posts/page.tsx
import { dehydrate, HydrationBoundary } from '@tanstack/react-query'
import { getQueryClient } from './get-query-client'
import Posts from './posts'

// the function doesn't need to be `async` because we don't `await` anything
export default function PostsPage() {
  const queryClient = getQueryClient()

  // look ma, no await
  queryClient.prefetchQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <Posts />
    </HydrationBoundary>
  )
}
```

On the client, the Promise will be put into the QueryCache for us. That means we can now call `useSuspenseQuery` inside the `Posts` component to "use" that Promise (which was created on the Server):

```tsx
// app/posts/posts.tsx
'use client'

export default function Posts() {
  const { data } = useSuspenseQuery({ queryKey: ['posts'], queryFn: getPosts })

  // ...
}
```

> Note that you could also `useQuery` instead of `useSuspenseQuery`, and the Promise would still be picked up correctly. However, NextJs won't suspend in that case and the component will render in the `pending` status, which also opts out of server rendering the content.

If you're using non-JSON data types and serialize the query results on the server, you can specify the `dehydrate.serializeData` and `hydrate.deserializeData` options to serialize and deserialize the data on each side of the boundary to ensure the data in the cache is the same format both on the server and the client:

```tsx
// app/get-query-client.ts
import { QueryClient, defaultShouldDehydrateQuery } from '@tanstack/react-query'
import { deserialize, serialize } from './transformer'

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      // ...
      hydrate: {
        deserializeData: deserialize,
      },
      dehydrate: {
        serializeData: serialize,
      },
    },
  })
}

// ...
```

```tsx
// app/posts/page.tsx
import {
  dehydrate,
  HydrationBoundary,
  QueryClient,
} from '@tanstack/react-query'
import { getQueryClient } from './get-query-client'
import { serialize } from './transformer'
import Posts from './posts'

export default function PostsPage() {
  const queryClient = getQueryClient()

  // look ma, no await
  queryClient.prefetchQuery({
    queryKey: ['posts'],
    queryFn: () => getPosts().then(serialize), // <-- serialize the data on the server
  })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <Posts />
    </HydrationBoundary>
  )
}
```

```tsx
// app/posts/posts.tsx
'use client'

export default function Posts() {
  const { data } = useSuspenseQuery({ queryKey: ['posts'], queryFn: getPosts })

  // ...
}
```

Now, your `getPosts` function can return e.g. `Temporal` datetime objects and the data will be serialized and deserialized on the client, assuming your transformer can serialize and deserialize those data types.

For more information, check out the [Next.js App with Prefetching Example](../../examples/nextjs-app-prefetching).

## Experimental streaming without prefetching in Next.js

While we recommend the prefetching solution detailed above because it flattens request waterfalls both on the initial page load **and** any subsequent page navigation, there is an experimental way to skip prefetching altogether and still have streaming SSR work: `@tanstack/react-query-next-experimental`

This package will allow you to fetch data on the server (in a Client Component) by just calling `useSuspenseQuery` in your component. Results will then be streamed from the server to the client as SuspenseBoundaries resolve. If you call `useSuspenseQuery` without wrapping it in a `<Suspense>` boundary, the HTML response won't start until the fetch resolves. This can be when you want depending on the situation, but keep in mind that this will hurt your TTFB.

To achieve this, wrap your app in the `ReactQueryStreamedHydration` component:

```tsx
// app/providers.tsx
'use client'

import {
  isServer,
  QueryClient,
  QueryClientProvider,
} from '@tanstack/react-query'
import * as React from 'react'
import { ReactQueryStreamedHydration } from '@tanstack/react-query-next-experimental'

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        // With SSR, we usually want to set some default staleTime
        // above 0 to avoid refetching immediately on the client
        staleTime: 60 * 1000,
      },
    },
  })
}

let browserQueryClient: QueryClient | undefined = undefined

function getQueryClient() {
  if (isServer) {
    // Server: always make a new query client
    return makeQueryClient()
  } else {
    // Browser: make a new query client if we don't already have one
    // This is very important, so we don't re-make a new client if React
    // suspends during the initial render. This may not be needed if we
    // have a suspense boundary BELOW the creation of the query client
    if (!browserQueryClient) browserQueryClient = makeQueryClient()
    return browserQueryClient
  }
}

export function Providers(props: { children: React.ReactNode }) {
  // NOTE: Avoid useState when initializing the query client if you don't
  //       have a suspense boundary between this and the code that may
  //       suspend because React will throw away the client on the initial
  //       render if it suspends and there is no boundary
  const queryClient = getQueryClient()

  return (
    <QueryClientProvider client={queryClient}>
      <ReactQueryStreamedHydration>
        {props.children}
      </ReactQueryStreamedHydration>
    </QueryClientProvider>
  )
}
```

For more information, check out the [NextJs Suspense Streaming Example](../../examples/nextjs-suspense-streaming).

The big upside is that you no longer need to prefetch queries manually to have SSR work, and it even still streams in the result! This gives you phenomenal DX and lower code complexity.

The downside is easiest to explain if we look back at [the complex request waterfall example](../request-waterfalls#code-splitting) in the Performance & Request Waterfalls guide. Server Components with prefetching effectively eliminates the request waterfalls both for the initial page load **and** any subsequent navigation. This prefetch-less approach however will only flatten the waterfalls on the initial page load but ends up the same deep waterfall as the original example on page navigations:

```
1. |> JS for <Feed>
2.   |> getFeed()
3.     |> JS for <GraphFeedItem>
4.       |> getGraphDataById()
```

This is even worse than with `getServerSideProps`/`getStaticProps`, since with those we could at least parallelize data- and code-fetching.

If you value DX/iteration/shipping speed with low code complexity over performance, don't have deeply nested queries, or are on top of your request waterfalls with parallel fetching using tools like `useSuspenseQueries`, this can be a good tradeoff.

> It might be possible to combine the two approaches, but even we haven't tried that out yet. If you do try this, please report back your findings, or even update these docs with some tips!

## Final words

Server Components and streaming are still fairly new concepts and we are still figuring out how React Query fits in and what improvements we can make to the API. We welcome suggestions, feedback and bug reports!

Similarly, it would be impossible to teach all the intricacies of this new paradigm all in one guide, on the first try. If you are missing some piece of information here or have suggestions on how to improve this content, also get in touch, or even better, click the "Edit on GitHub" button below and help us out.

---

# background-fetching-indicators


---
id: background-fetching-indicators
title: Background Fetching Indicators
---

A query's `status === 'pending'` state is sufficient enough to show the initial hard-loading state for a query, but sometimes you may want to display an additional indicator that a query is refetching in the background. To do this, queries also supply you with an `isFetching` boolean that you can use to show that it's in a fetching state, regardless of the state of the `status` variable:

[//]: # 'Example'

```tsx
function Todos() {
  const {
    status,
    data: todos,
    error,
    isFetching,
  } = useQuery({
    queryKey: ['todos'],
    queryFn: fetchTodos,
  })

  return status === 'pending' ? (
    <span>Loading...</span>
  ) : status === 'error' ? (
    <span>Error: {error.message}</span>
  ) : (
    <>
      {isFetching ? <div>Refreshing...</div> : null}

      <div>
        {todos.map((todo) => (
          <Todo todo={todo} />
        ))}
      </div>
    </>
  )
}
```

[//]: # 'Example'

## Displaying Global Background Fetching Loading State

In addition to individual query loading states, if you would like to show a global loading indicator when **any** queries are fetching (including in the background), you can use the `useIsFetching` hook:

[//]: # 'Example2'

```tsx
import { useIsFetching } from '@tanstack/react-query'

function GlobalLoadingIndicator() {
  const isFetching = useIsFetching()

  return isFetching ? (
    <div>Queries are fetching in the background...</div>
  ) : null
}
```

[//]: # 'Example2'

---

# caching


---
id: caching
title: Caching Examples
---

> Please thoroughly read the [Important Defaults](../important-defaults) before reading this guide

## Basic Example

This caching example illustrates the story and lifecycle of:

- Query Instances with and without cache data
- Background Refetching
- Inactive Queries
- Garbage Collection

Let's assume we are using the default `gcTime` of **5 minutes** and the default `staleTime` of `0`.

- A new instance of `useQuery({ queryKey: ['todos'], queryFn: fetchTodos })` mounts.
  - Since no other queries have been made with the `['todos']` query key, this query will show a hard loading state and make a network request to fetch the data.
  - When the network request has completed, the returned data will be cached under the `['todos']` key.
  - The hook will mark the data as stale after the configured `staleTime` (defaults to `0`, or immediately).
- A second instance of `useQuery({ queryKey: ['todos'], queryFn: fetchTodos })` mounts elsewhere.
  - Since the cache already has data for the `['todos']` key from the first query, that data is immediately returned from the cache.
  - The new instance triggers a new network request using its query function.
    - Note that regardless of whether both `fetchTodos` query functions are identical or not, both queries' [`status`](../../reference/useQuery) are updated (including `isFetching`, `isPending`, and other related values) because they have the same query key.
  - When the request completes successfully, the cache's data under the `['todos']` key is updated with the new data, and both instances are updated with the new data.
- Both instances of the `useQuery({ queryKey: ['todos'], queryFn: fetchTodos })` query are unmounted and no longer in use.
  - Since there are no more active instances of this query, a garbage collection timeout is set using `gcTime` to delete and garbage collect the query (defaults to **5 minutes**).
- Before the cache timeout has completed, another instance of `useQuery({ queryKey: ['todos'], queryFn: fetchTodos })` mounts. The query immediately returns the available cached data while the `fetchTodos` function is being run in the background. When it completes successfully, it will populate the cache with fresh data.
- The final instance of `useQuery({ queryKey: ['todos'], queryFn: fetchTodos })` unmounts.
- No more instances of `useQuery({ queryKey: ['todos'], queryFn: fetchTodos })` appear within **5 minutes**.
  - The cached data under the `['todos']` key is deleted and garbage collected.

---

# default-query-function


---
id: default-query-function
title: Default Query Function
---

If you find yourself wishing for whatever reason that you could just share the same query function for your entire app and just use query keys to identify what it should fetch, you can do that by providing a **default query function** to TanStack Query:

[//]: # 'Example'

```tsx
// Define a default query function that will receive the query key
const defaultQueryFn = async ({ queryKey }) => {
  const { data } = await axios.get(
    `https://jsonplaceholder.typicode.com${queryKey[0]}`,
  )
  return data
}

// provide the default query function to your app with defaultOptions
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      queryFn: defaultQueryFn,
    },
  },
})

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <YourApp />
    </QueryClientProvider>
  )
}

// All you have to do now is pass a key!
function Posts() {
  const { status, data, error, isFetching } = useQuery({ queryKey: ['/posts'] })

  // ...
}

// You can even leave out the queryFn and just go straight into options
function Post({ postId }) {
  const { status, data, error, isFetching } = useQuery({
    queryKey: [`/posts/${postId}`],
    enabled: !!postId,
  })

  // ...
}
```

[//]: # 'Example'

If you ever want to override the default queryFn, you can just provide your own like you normally would.

---

# dependent-queries


---
id: dependent-queries
title: Dependent Queries
---

## useQuery dependent Query

Dependent (or serial) queries depend on previous ones to finish before they can execute. To achieve this, it's as easy as using the `enabled` option to tell a query when it is ready to run:

[//]: # 'Example'

```tsx
// Get the user
const { data: user } = useQuery({
  queryKey: ['user', email],
  queryFn: getUserByEmail,
})

const userId = user?.id

// Then get the user's projects
const {
  status,
  fetchStatus,
  data: projects,
} = useQuery({
  queryKey: ['projects', userId],
  queryFn: getProjectsByUser,
  // The query will not execute until the userId exists
  enabled: !!userId,
})
```

[//]: # 'Example'

The `projects` query will start in:

```tsx
status: 'pending'
isPending: true
fetchStatus: 'idle'
```

As soon as the `user` is available, the `projects` query will be `enabled` and will then transition to:

```tsx
status: 'pending'
isPending: true
fetchStatus: 'fetching'
```

Once we have the projects, it will go to:

```tsx
status: 'success'
isPending: false
fetchStatus: 'idle'
```

## useQueries dependent Query

Dynamic parallel query - `useQueries` can depend on a previous query also, here's how to achieve this:

[//]: # 'Example2'

```tsx
// Get the users ids
const { data: userIds } = useQuery({
  queryKey: ['users'],
  queryFn: getUsersData,
  select: (users) => users.map((user) => user.id),
})

// Then get the users messages
const usersMessages = useQueries({
  queries: userIds
    ? userIds.map((id) => {
        return {
          queryKey: ['messages', id],
          queryFn: () => getMessagesByUsers(id),
        }
      })
    : [], // if users is undefined, an empty array will be returned
})
```

[//]: # 'Example2'

**Note** that `useQueries` return an **array of query results**

## A note about performance

Dependent queries by definition constitutes a form of [request waterfall](../../../react/guides/request-waterfalls), which hurts performance. If we pretend both queries take the same amount of time, doing them serially instead of in parallel always takes twice as much time, which is especially hurtful when it happens on a client that has high latency. If you can, it's always better to restructure the backend APIs so that both queries can be fetched in parallel, though that might not always be practically feasible.

In the example above, instead of first fetching `getUserByEmail` to be able to `getProjectsByUser`, introducing a new `getProjectsByUserEmail` query would flatten the waterfall.

---

# disabling-queries


---
id: disabling-queries
title: Disabling/Pausing Queries
---

If you ever want to disable a query from automatically running, you can use the `enabled = false` option. The enabled option also accepts a callback that returns a boolean.

When `enabled` is `false`:

- If the query has cached data, then the query will be initialized in the `status === 'success'` or `isSuccess` state.
- If the query does not have cached data, then the query will start in the `status === 'pending'` and `fetchStatus === 'idle'` state.
- The query will not automatically fetch on mount.
- The query will not automatically refetch in the background.
- The query will ignore query client `invalidateQueries` and `refetchQueries` calls that would normally result in the query refetching.
- `refetch` returned from `useQuery` can be used to manually trigger the query to fetch. However, it will not work with `skipToken`.

> TypeScript users may prefer to use [skipToken](#typesafe-disabling-of-queries-using-skiptoken) as an alternative to `enabled = false`.

[//]: # 'Example'

```tsx
function Todos() {
  const { isLoading, isError, data, error, refetch, isFetching } = useQuery({
    queryKey: ['todos'],
    queryFn: fetchTodoList,
    enabled: false,
  })

  return (
    <div>
      <button onClick={() => refetch()}>Fetch Todos</button>

      {data ? (
        <>
          <ul>
            {data.map((todo) => (
              <li key={todo.id}>{todo.title}</li>
            ))}
          </ul>
        </>
      ) : isError ? (
        <span>Error: {error.message}</span>
      ) : isLoading ? (
        <span>Loading...</span>
      ) : (
        <span>Not ready ...</span>
      )}

      <div>{isFetching ? 'Fetching...' : null}</div>
    </div>
  )
}
```

[//]: # 'Example'

Permanently disabling a query opts out of many great features that TanStack Query has to offer (like background refetches), and it's also not the idiomatic way. It takes you from the declarative approach (defining dependencies when your query should run) into an imperative mode (fetch whenever I click here). It is also not possible to pass parameters to `refetch`. Oftentimes, all you want is a lazy query that defers the initial fetch:

## Lazy Queries

The enabled option can not only be used to permanently disable a query, but also to enable / disable it at a later time. A good example would be a filter form where you only want to fire off the first request once the user has entered a filter value:

[//]: # 'Example2'

```tsx
function Todos() {
  const [filter, setFilter] = React.useState('')

  const { data } = useQuery({
    queryKey: ['todos', filter],
    queryFn: () => fetchTodos(filter),
    // ⬇️ disabled as long as the filter is empty
    enabled: !!filter,
  })

  return (
    <div>
      // 🚀 applying the filter will enable and execute the query
      <FiltersForm onApply={setFilter} />
      {data && <TodosTable data={data} />}
    </div>
  )
}
```

[//]: # 'Example2'

### isLoading (Previously: `isInitialLoading`)

Lazy queries will be in `status: 'pending'` right from the start because `pending` means that there is no data yet. This is technically true, however, since we are not currently fetching any data (as the query is not _enabled_), it also means you likely cannot use this flag to show a loading spinner.

If you are using disabled or lazy queries, you can use the `isLoading` flag instead. It's a derived flag that is computed from:

`isPending && isFetching`

so it will only be true if the query is currently fetching for the first time.

## Typesafe disabling of queries using `skipToken`

If you are using TypeScript, you can use the `skipToken` to disable a query. This is useful when you want to disable a query based on a condition, but you still want to keep the query to be type safe.

> IMPORTANT: `refetch` from `useQuery` will not work with `skipToken`. Other than that, `skipToken` works the same as `enabled: false`.

[//]: # 'Example3'

```tsx
function Todos() {
  const [filter, setFilter] = React.useState<string | undefined>()

  const { data } = useQuery({
    queryKey: ['todos', filter],
    // ⬇️ disabled as long as the filter is undefined or empty
    queryFn: filter ? () => fetchTodos(filter) : skipToken,
  })

  return (
    <div>
      // 🚀 applying the filter will enable and execute the query
      <FiltersForm onApply={setFilter} />
      {data && <TodosTable data={data} />}
    </div>
  )
}
```

[//]: # 'Example3'

---

# does-this-replace-client-state


---
id: does-this-replace-client-state
title: Does TanStack Query replace Redux, MobX or other global state managers?
---

Well, let's start with a few important items:

- TanStack Query is a **server-state** library, responsible for managing asynchronous operations between your server and client
- Redux, MobX, Zustand, etc. are **client-state** libraries that _can be used to store asynchronous data, albeit inefficiently when compared to a tool like TanStack Query_

With those points in mind, the short answer is that TanStack Query **replaces the boilerplate code and related wiring used to manage cache data in your client-state and replaces it with just a few lines of code.**

For a vast majority of applications, the truly **globally accessible client state** that is left over after migrating all of your async code to TanStack Query is usually very tiny.

> There are still some circumstances where an application might indeed have a massive amount of synchronous client-only state (like a visual designer or music production application), in which case, you will probably still want a client state manager. In this situation it's important to note that **TanStack Query is not a replacement for local/client state management**. However, you can use TanStack Query alongside most client state managers with zero issues.

## A Contrived Example

Here we have some "global" state being managed by a global state library:

```tsx
const globalState = {
  projects,
  teams,
  tasks,
  users,
  themeMode,
  sidebarStatus,
}
```

Currently, the global state manager is caching 4 types of server-state: `projects`, `teams`, `tasks`, and `users`. If we were to move these server-state assets to TanStack Query, our remaining global state would look more like this:

```tsx
const globalState = {
  themeMode,
  sidebarStatus,
}
```

This also means that with a few hook calls to `useQuery` and `useMutation`, we also get to remove any boilerplate code that was used to manage our server state e.g.

- Connectors
- Action Creators
- Middlewares
- Reducers
- Loading/Error/Result states
- Contexts

With all of those things removed, you may ask yourself, **"Is it worth it to keep using our client state manager for this tiny global state?"**

**And that's up to you!**

But TanStack Query's role is clear. It removes asynchronous wiring and boilerplate from your application and replaces it with just a few lines of code.

What are you waiting for, give it a go already!

---

# filters


---
id: filters
title: Filters
---

Some methods within TanStack Query accept a `QueryFilters` or `MutationFilters` object.

## `Query Filters`

A query filter is an object with certain conditions to match a query with:

```tsx
// Cancel all queries
await queryClient.cancelQueries()

// Remove all inactive queries that begin with `posts` in the key
queryClient.removeQueries({ queryKey: ['posts'], type: 'inactive' })

// Refetch all active queries
await queryClient.refetchQueries({ type: 'active' })

// Refetch all active queries that begin with `posts` in the key
await queryClient.refetchQueries({ queryKey: ['posts'], type: 'active' })
```

A query filter object supports the following properties:

- `queryKey?: QueryKey`
  - Set this property to define a query key to match on.
- `exact?: boolean`
  - If you don't want to search queries inclusively by query key, you can pass the `exact: true` option to return only the query with the exact query key you have passed.
- `type?: 'active' | 'inactive' | 'all'`
  - Defaults to `all`
  - When set to `active` it will match active queries.
  - When set to `inactive` it will match inactive queries.
- `stale?: boolean`
  - When set to `true` it will match stale queries.
  - When set to `false` it will match fresh queries.
- `fetchStatus?: FetchStatus`
  - When set to `fetching` it will match queries that are currently fetching.
  - When set to `paused` it will match queries that wanted to fetch, but have been `paused`.
  - When set to `idle` it will match queries that are not fetching.
- `predicate?: (query: Query) => boolean`
  - This predicate function will be used as a final filter on all matching queries. If no other filters are specified, this function will be evaluated against every query in the cache.

## `Mutation Filters`

A mutation filter is an object with certain conditions to match a mutation with:

```tsx
// Get the number of all fetching mutations
await queryClient.isMutating()

// Filter mutations by mutationKey
await queryClient.isMutating({ mutationKey: ['post'] })

// Filter mutations using a predicate function
await queryClient.isMutating({
  predicate: (mutation) => mutation.options.variables?.id === 1,
})
```

A mutation filter object supports the following properties:

- `mutationKey?: MutationKey`
  - Set this property to define a mutation key to match on.
- `exact?: boolean`
  - If you don't want to search mutations inclusively by mutation key, you can pass the `exact: true` option to return only the mutation with the exact mutation key you have passed.
- `status?: MutationStatus`
  - Allows for filtering mutations according to their status.
- `predicate?: (mutation: Mutation) => boolean`
  - This predicate function will be used as a final filter on all matching mutations. If no other filters are specified, this function will be evaluated against every mutation in the cache.

## Utils

### `matchQuery`

```tsx
const isMatching = matchQuery(filters, query)
```

Returns a boolean that indicates whether a query matches the provided set of query filters.

### `matchMutation`

```tsx
const isMatching = matchMutation(filters, mutation)
```

Returns a boolean that indicates whether a mutation matches the provided set of mutation filters.

---

# important-defaults


---
id: important-defaults
title: Important Defaults
---

Out of the box, TanStack Query is configured with **aggressive but sane** defaults. **Sometimes these defaults can catch new users off guard or make learning/debugging difficult if they are unknown by the user.** Keep them in mind as you continue to learn and use TanStack Query:

- Query instances via `useQuery` or `useInfiniteQuery` by default **consider cached data as stale**.

> To change this behavior, you can configure your queries both globally and per-query using the `staleTime` option. Specifying a longer `staleTime` means queries will not refetch their data as often

- Stale queries are refetched automatically in the background when:
  - New instances of the query mount
  - The window is refocused
  - The network is reconnected
  - The query is optionally configured with a refetch interval

> To change this functionality, you can use options like `refetchOnMount`, `refetchOnWindowFocus`, `refetchOnReconnect` and `refetchInterval`.

- Query results that have no more active instances of `useQuery`, `useInfiniteQuery` or query observers are labeled as "inactive" and remain in the cache in case they are used again at a later time.
- By default, "inactive" queries are garbage collected after **5 minutes**.

  > To change this, you can alter the default `gcTime` for queries to something other than `1000 * 60 * 5` milliseconds.

- Queries that fail are **silently retried 3 times, with exponential backoff delay** before capturing and displaying an error to the UI.

  > To change this, you can alter the default `retry` and `retryDelay` options for queries to something other than `3` and the default exponential backoff function.

- Query results by default are **structurally shared to detect if data has actually changed** and if not, **the data reference remains unchanged** to better help with value stabilization with regards to useMemo and useCallback. If this concept sounds foreign, then don't worry about it! 99.9% of the time you will not need to disable this and it makes your app more performant at zero cost to you.

  > Structural sharing only works with JSON-compatible values, any other value types will always be considered as changed. If you are seeing performance issues because of large responses for example, you can disable this feature with the `config.structuralSharing` flag. If you are dealing with non-JSON compatible values in your query responses and still want to detect if data has changed or not, you can provide your own custom function as `config.structuralSharing` to compute a value from the old and new responses, retaining references as required.

[//]: # 'Materials'

## Further Reading

Have a look at the following articles from our Community Resources for further explanations of the defaults:

- [Practical React Query](../../community/tkdodos-blog#1-practical-react-query)
- [React Query as a State Manager](../../community/tkdodos-blog#10-react-query-as-a-state-manager)

[//]: # 'Materials'

---

# infinite-queries


---
id: infinite-queries
title: Infinite Queries
---

Rendering lists that can additively "load more" data onto an existing set of data or "infinite scroll" is also a very common UI pattern. TanStack Query supports a useful version of `useQuery` called `useInfiniteQuery` for querying these types of lists.

When using `useInfiniteQuery`, you'll notice a few things are different:

- `data` is now an object containing infinite query data:
- `data.pages` array containing the fetched pages
- `data.pageParams` array containing the page params used to fetch the pages
- The `fetchNextPage` and `fetchPreviousPage` functions are now available (`fetchNextPage` is required)
- The `initialPageParam` option is now available (and required) to specify the initial page param
- The `getNextPageParam` and `getPreviousPageParam` options are available for both determining if there is more data to load and the information to fetch it. This information is supplied as an additional parameter in the query function
- A `hasNextPage` boolean is now available and is `true` if `getNextPageParam` returns a value other than `null` or `undefined`
- A `hasPreviousPage` boolean is now available and is `true` if `getPreviousPageParam` returns a value other than `null` or `undefined`
- The `isFetchingNextPage` and `isFetchingPreviousPage` booleans are now available to distinguish between a background refresh state and a loading more state

> Note: Options `initialData` or `placeholderData` need to conform to the same structure of an object with `data.pages` and `data.pageParams` properties.

## Example

Let's assume we have an API that returns pages of `projects` 3 at a time based on a `cursor` index along with a cursor that can be used to fetch the next group of projects:

```tsx
fetch('/api/projects?cursor=0')
// { data: [...], nextCursor: 3}
fetch('/api/projects?cursor=3')
// { data: [...], nextCursor: 6}
fetch('/api/projects?cursor=6')
// { data: [...], nextCursor: 9}
fetch('/api/projects?cursor=9')
// { data: [...] }
```

With this information, we can create a "Load More" UI by:

- Waiting for `useInfiniteQuery` to request the first group of data by default
- Returning the information for the next query in `getNextPageParam`
- Calling `fetchNextPage` function

[//]: # 'Example'

```tsx
import { useInfiniteQuery } from '@tanstack/react-query'

function Projects() {
  const fetchProjects = async ({ pageParam }) => {
    const res = await fetch('/api/projects?cursor=' + pageParam)
    return res.json()
  }

  const {
    data,
    error,
    fetchNextPage,
    hasNextPage,
    isFetching,
    isFetchingNextPage,
    status,
  } = useInfiniteQuery({
    queryKey: ['projects'],
    queryFn: fetchProjects,
    initialPageParam: 0,
    getNextPageParam: (lastPage, pages) => lastPage.nextCursor,
  })

  return status === 'pending' ? (
    <p>Loading...</p>
  ) : status === 'error' ? (
    <p>Error: {error.message}</p>
  ) : (
    <>
      {data.pages.map((group, i) => (
        <React.Fragment key={i}>
          {group.data.map((project) => (
            <p key={project.id}>{project.name}</p>
          ))}
        </React.Fragment>
      ))}
      <div>
        <button
          onClick={() => fetchNextPage()}
          disabled={!hasNextPage || isFetchingNextPage}
        >
          {isFetchingNextPage
            ? 'Loading more...'
            : hasNextPage
              ? 'Load More'
              : 'Nothing more to load'}
        </button>
      </div>
      <div>{isFetching && !isFetchingNextPage ? 'Fetching...' : null}</div>
    </>
  )
}
```

[//]: # 'Example'

It's essential to understand that calling `fetchNextPage` while an ongoing fetch is in progress runs the risk of overwriting data refreshes happening in the background. This situation becomes particularly critical when rendering a list and triggering `fetchNextPage` simultaneously.

Remember, there can only be a single ongoing fetch for an InfiniteQuery. A single cache entry is shared for all pages, attempting to fetch twice simultaneously might lead to data overwrites.

If you intend to enable simultaneous fetching, you can utilize the `{ cancelRefetch: false }` option (default: true) within `fetchNextPage`.

To ensure a seamless querying process without conflicts, it's highly recommended to verify that the query is not in an `isFetching` state, especially if the user won't directly control that call.

[//]: # 'Example1'

```jsx
<List onEndReached={() => !isFetchingNextPage && fetchNextPage()} />
```

[//]: # 'Example1'

## What happens when an infinite query needs to be refetched?

When an infinite query becomes `stale` and needs to be refetched, each group is fetched `sequentially`, starting from the first one. This ensures that even if the underlying data is mutated, we're not using stale cursors and potentially getting duplicates or skipping records. If an infinite query's results are ever removed from the queryCache, the pagination restarts at the initial state with only the initial group being requested.

## What if I want to implement a bi-directional infinite list?

Bi-directional lists can be implemented by using the `getPreviousPageParam`, `fetchPreviousPage`, `hasPreviousPage` and `isFetchingPreviousPage` properties and functions.

[//]: # 'Example3'

```tsx
useInfiniteQuery({
  queryKey: ['projects'],
  queryFn: fetchProjects,
  initialPageParam: 0,
  getNextPageParam: (lastPage, pages) => lastPage.nextCursor,
  getPreviousPageParam: (firstPage, pages) => firstPage.prevCursor,
})
```

[//]: # 'Example3'

## What if I want to show the pages in reversed order?

Sometimes you may want to show the pages in reversed order. If this is case, you can use the `select` option:

[//]: # 'Example4'

```tsx
useInfiniteQuery({
  queryKey: ['projects'],
  queryFn: fetchProjects,
  select: (data) => ({
    pages: [...data.pages].reverse(),
    pageParams: [...data.pageParams].reverse(),
  }),
})
```

[//]: # 'Example4'

## What if I want to manually update the infinite query?

### Manually removing first page:

[//]: # 'Example5'

```tsx
queryClient.setQueryData(['projects'], (data) => ({
  pages: data.pages.slice(1),
  pageParams: data.pageParams.slice(1),
}))
```

[//]: # 'Example5'

### Manually removing a single value from an individual page:

[//]: # 'Example6'

```tsx
const newPagesArray =
  oldPagesArray?.pages.map((page) =>
    page.filter((val) => val.id !== updatedId),
  ) ?? []

queryClient.setQueryData(['projects'], (data) => ({
  pages: newPagesArray,
  pageParams: data.pageParams,
}))
```

[//]: # 'Example6'

### Keep only the first page:

[//]: # 'Example7'

```tsx
queryClient.setQueryData(['projects'], (data) => ({
  pages: data.pages.slice(0, 1),
  pageParams: data.pageParams.slice(0, 1),
}))
```

[//]: # 'Example7'

Make sure to always keep the same data structure of pages and pageParams!

## What if I want to limit the number of pages?

In some use cases you may want to limit the number of pages stored in the query data to improve the performance and UX:

- when the user can load a large number of pages (memory usage)
- when you have to refetch an infinite query that contains dozens of pages (network usage: all the pages are sequentially fetched)

The solution is to use a "Limited Infinite Query". This is made possible by using the `maxPages` option in conjunction with `getNextPageParam` and `getPreviousPageParam` to allow fetching pages when needed in both directions.

In the following example only 3 pages are kept in the query data pages array. If a refetch is needed, only 3 pages will be refetched sequentially.

[//]: # 'Example8'

```tsx
useInfiniteQuery({
  queryKey: ['projects'],
  queryFn: fetchProjects,
  initialPageParam: 0,
  getNextPageParam: (lastPage, pages) => lastPage.nextCursor,
  getPreviousPageParam: (firstPage, pages) => firstPage.prevCursor,
  maxPages: 3,
})
```

[//]: # 'Example8'

## What if my API doesn't return a cursor?

If your API doesn't return a cursor, you can use the `pageParam` as a cursor. Because `getNextPageParam` and `getPreviousPageParam` also get the `pageParam`of the current page, you can use it to calculate the next / previous page param.

[//]: # 'Example9'

```tsx
return useInfiniteQuery({
  queryKey: ['projects'],
  queryFn: fetchProjects,
  initialPageParam: 0,
  getNextPageParam: (lastPage, allPages, lastPageParam) => {
    if (lastPage.length === 0) {
      return undefined
    }
    return lastPageParam + 1
  },
  getPreviousPageParam: (firstPage, allPages, firstPageParam) => {
    if (firstPageParam <= 1) {
      return undefined
    }
    return firstPageParam - 1
  },
})
```

[//]: # 'Example9'

---

# initial-query-data


---
id: initial-query-data
title: Initial Query Data
---

There are many ways to supply initial data for a query to the cache before you need it:

- Declaratively:
  - Provide `initialData` to a query to prepopulate its cache if empty
- Imperatively:
  - [Prefetch the data using `queryClient.prefetchQuery`](../../../react/guides/prefetching)
  - [Manually place the data into the cache using `queryClient.setQueryData`](../../../react/guides/prefetching)

## Using `initialData` to prepopulate a query

There may be times when you already have the initial data for a query available in your app and can simply provide it directly to your query. If and when this is the case, you can use the `config.initialData` option to set the initial data for a query and skip the initial loading state!

> IMPORTANT: `initialData` is persisted to the cache, so it is not recommended to provide placeholder, partial or incomplete data to this option and instead use `placeholderData`

[//]: # 'Example'

```tsx
const result = useQuery({
  queryKey: ['todos'],
  queryFn: () => fetch('/todos'),
  initialData: initialTodos,
})
```

[//]: # 'Example'

### `staleTime` and `initialDataUpdatedAt`

By default, `initialData` is treated as totally fresh, as if it were just fetched. This also means that it will affect how it is interpreted by the `staleTime` option.

- If you configure your query observer with `initialData`, and no `staleTime` (the default `staleTime: 0`), the query will immediately refetch when it mounts:

  [//]: # 'Example2'

  ```tsx
  // Will show initialTodos immediately, but also immediately refetch todos after mount
  const result = useQuery({
    queryKey: ['todos'],
    queryFn: () => fetch('/todos'),
    initialData: initialTodos,
  })
  ```

  [//]: # 'Example2'

- If you configure your query observer with `initialData` and a `staleTime` of `1000` ms, the data will be considered fresh for that same amount of time, as if it was just fetched from your query function.

  [//]: # 'Example3'

  ```tsx
  // Show initialTodos immediately, but won't refetch until another interaction event is encountered after 1000 ms
  const result = useQuery({
    queryKey: ['todos'],
    queryFn: () => fetch('/todos'),
    initialData: initialTodos,
    staleTime: 1000,
  })
  ```

  [//]: # 'Example3'

- So what if your `initialData` isn't totally fresh? That leaves us with the last configuration that is actually the most accurate and uses an option called `initialDataUpdatedAt`. This option allows you to pass a numeric JS timestamp in milliseconds of when the initialData itself was last updated, e.g. what `Date.now()` provides. Take note that if you have a unix timestamp, you'll need to convert it to a JS timestamp by multiplying it by `1000`.

  [//]: # 'Example4'

  ```tsx
  // Show initialTodos immediately, but won't refetch until another interaction event is encountered after 1000 ms
  const result = useQuery({
    queryKey: ['todos'],
    queryFn: () => fetch('/todos'),
    initialData: initialTodos,
    staleTime: 60 * 1000, // 1 minute
    // This could be 10 seconds ago or 10 minutes ago
    initialDataUpdatedAt: initialTodosUpdatedTimestamp, // eg. 1608412420052
  })
  ```

  [//]: # 'Example4'

  This option allows the staleTime to be used for its original purpose, determining how fresh the data needs to be, while also allowing the data to be refetched on mount if the `initialData` is older than the `staleTime`. In the example above, our data needs to be fresh within 1 minute, and we can hint to the query when the initialData was last updated so the query can decide for itself whether the data needs to be refetched again or not.

  > If you would rather treat your data as **prefetched data**, we recommend that you use the `prefetchQuery` or `fetchQuery` APIs to populate the cache beforehand, thus letting you configure your `staleTime` independently from your initialData

### Initial Data Function

If the process for accessing a query's initial data is intensive or just not something you want to perform on every render, you can pass a function as the `initialData` value. This function will be executed only once when the query is initialized, saving you precious memory and/or CPU:

[//]: # 'Example5'

```tsx
const result = useQuery({
  queryKey: ['todos'],
  queryFn: () => fetch('/todos'),
  initialData: () => getExpensiveTodos(),
})
```

[//]: # 'Example5'

### Initial Data from Cache

In some circumstances, you may be able to provide the initial data for a query from the cached result of another. A good example of this would be searching the cached data from a todos list query for an individual todo item, then using that as the initial data for your individual todo query:

[//]: # 'Example6'

```tsx
const result = useQuery({
  queryKey: ['todo', todoId],
  queryFn: () => fetch('/todos'),
  initialData: () => {
    // Use a todo from the 'todos' query as the initial data for this todo query
    return queryClient.getQueryData(['todos'])?.find((d) => d.id === todoId)
  },
})
```

[//]: # 'Example6'

### Initial Data from the cache with `initialDataUpdatedAt`

Getting initial data from the cache means the source query you're using to look up the initial data from is likely old. Instead of using an artificial `staleTime` to keep your query from refetching immediately, it's suggested that you pass the source query's `dataUpdatedAt` to `initialDataUpdatedAt`. This provides the query instance with all the information it needs to determine if and when the query needs to be refetched, regardless of initial data being provided.

[//]: # 'Example7'

```tsx
const result = useQuery({
  queryKey: ['todos', todoId],
  queryFn: () => fetch(`/todos/${todoId}`),
  initialData: () =>
    queryClient.getQueryData(['todos'])?.find((d) => d.id === todoId),
  initialDataUpdatedAt: () =>
    queryClient.getQueryState(['todos'])?.dataUpdatedAt,
})
```

[//]: # 'Example7'

### Conditional Initial Data from Cache

If the source query you're using to look up the initial data from is old, you may not want to use the cached data at all and just fetch from the server. To make this decision easier, you can use the `queryClient.getQueryState` method instead to get more information about the source query, including a `state.dataUpdatedAt` timestamp you can use to decide if the query is "fresh" enough for your needs:

[//]: # 'Example8'

```tsx
const result = useQuery({
  queryKey: ['todo', todoId],
  queryFn: () => fetch(`/todos/${todoId}`),
  initialData: () => {
    // Get the query state
    const state = queryClient.getQueryState(['todos'])

    // If the query exists and has data that is no older than 10 seconds...
    if (state && Date.now() - state.dataUpdatedAt <= 10 * 1000) {
      // return the individual todo
      return state.data.find((d) => d.id === todoId)
    }

    // Otherwise, return undefined and let it fetch from a hard loading state!
  },
})
```

[//]: # 'Example8'
[//]: # 'Materials'

## Further reading

For a comparison between `Initial Data` and `Placeholder Data`, have a look at the [Community Resources](../../community/tkdodos-blog#9-placeholder-and-initial-data-in-react-query).

[//]: # 'Materials'

---

# invalidations-from-mutations


---
id: invalidations-from-mutations
title: Invalidations from Mutations
---

Invalidating queries is only half the battle. Knowing **when** to invalidate them is the other half. Usually when a mutation in your app succeeds, it's VERY likely that there are related queries in your application that need to be invalidated and possibly refetched to account for the new changes from your mutation.

For example, assume we have a mutation to post a new todo:

[//]: # 'Example'

```tsx
const mutation = useMutation({ mutationFn: postTodo })
```

[//]: # 'Example'

When a successful `postTodo` mutation happens, we likely want all `todos` queries to get invalidated and possibly refetched to show the new todo item. To do this, you can use `useMutation`'s `onSuccess` options and the `client`'s `invalidateQueries` function:

[//]: # 'Example2'

```tsx
import { useMutation, useQueryClient } from '@tanstack/react-query'

const queryClient = useQueryClient()

// When this mutation succeeds, invalidate any queries with the `todos` or `reminders` query key
const mutation = useMutation({
  mutationFn: addTodo,
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ['todos'] })
    queryClient.invalidateQueries({ queryKey: ['reminders'] })
  },
})
```

[//]: # 'Example2'

You can wire up your invalidations to happen using any of the callbacks available in the [`useMutation` hook](../mutations)

---

# migrating-to-react-query-3


---
id: migrating-to-react-query-3
title: Migrating to React Query 3
---

Previous versions of React Query were awesome and brought some amazing new features, more magic, and an overall better experience to the library. They also brought on massive adoption and likewise a lot of refining fire (issues/contributions) to the library and brought to light a few things that needed more polish to make the library even better. v3 contains that very polish.

## Overview

- More scalable and testable cache configuration
- Better SSR support
- Data-lag (previously usePaginatedQuery) anywhere!
- Bi-directional Infinite Queries
- Query data selectors!
- Fully configure defaults for queries and/or mutations before use
- More granularity for optional rendering optimization
- New `useQueries` hook! (Variable-length parallel query execution)
- Query filter support for the `useIsFetching()` hook!
- Retry/offline/replay support for mutations
- Observe queries/mutations outside of React
- Use the React Query core logic anywhere you want!
- Bundled/Colocated Devtools via `react-query/devtools`
- Cache Persistence to web storage (experimental via `react-query/persistQueryClient-experimental` and `react-query/createWebStoragePersistor-experimental`)

## Breaking Changes

### The `QueryCache` has been split into a `QueryClient` and lower-level `QueryCache` and `MutationCache` instances.

The `QueryCache` contains all queries, the `MutationCache` contains all mutations, and the `QueryClient` can be used to set configuration and to interact with them.

This has some benefits:

- Allows for different types of caches.
- Multiple clients with different configurations can use the same cache.
- Clients can be used to track queries, which can be used for shared caches on SSR.
- The client API is more focused towards general usage.
- Easier to test the individual components.

When creating a `new QueryClient()`, a `QueryCache` and `MutationCache` are automatically created for you if you don't supply them.

```tsx
import { QueryClient } from 'react-query'

const queryClient = new QueryClient()
```

### `ReactQueryConfigProvider` and `ReactQueryCacheProvider` have both been replaced by `QueryClientProvider`

Default options for queries and mutations can now be specified in `QueryClient`:

**Notice that it's now defaultOptions instead of defaultConfig**

```tsx
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // query options
    },
    mutations: {
      // mutation options
    },
  },
})
```

The `QueryClientProvider` component is now used to connect a `QueryClient` to your application:

```tsx
import { QueryClient, QueryClientProvider } from 'react-query'

const queryClient = new QueryClient()

function App() {
  return <QueryClientProvider client={queryClient}>...</QueryClientProvider>
}
```

### The default `QueryCache` is gone. **For real this time!**

As previously noted with a deprecation, there is no longer a default `QueryCache` that is created or exported from the main package. **You must create your own via `new QueryClient()` or `new QueryCache()` (which you can then pass to `new QueryClient({ queryCache })` )**

### The deprecated `makeQueryCache` utility has been removed.

It's been a long time coming, but it's finally gone :)

### `QueryCache.prefetchQuery()` has been moved to `QueryClient.prefetchQuery()`

The new `QueryClient.prefetchQuery()` function is async, but **does not return the data from the query**. If you require the data, use the new `QueryClient.fetchQuery()` function

```tsx
// Prefetch a query:
await queryClient.prefetchQuery('posts', fetchPosts)

// Fetch a query:
try {
  const data = await queryClient.fetchQuery('posts', fetchPosts)
} catch (error) {
  // Error handling
}
```

### `ReactQueryErrorResetBoundary` and `QueryCache.resetErrorBoundaries()` have been replaced by `QueryErrorResetBoundary` and `useQueryErrorResetBoundary()`.

Together, these provide the same experience as before, but with added control to choose which component trees you want to reset. For more information, see:

- [QueryErrorResetBoundary](../../reference/QueryErrorResetBoundary)
- [useQueryErrorResetBoundary](../../reference/useQueryErrorResetBoundary)

### `QueryCache.getQuery()` has been replaced by `QueryCache.find()`.

`QueryCache.find()` should now be used to look up individual queries from a cache

### `QueryCache.getQueries()` has been moved to `QueryCache.findAll()`.

`QueryCache.findAll()` should now be used to look up multiple queries from a cache

### `QueryCache.isFetching` has been moved to `QueryClient.isFetching()`.

**Notice that it's now a function instead of a property**

### The `useQueryCache` hook has been replaced by the `useQueryClient` hook.

It returns the provided `queryClient` for its component tree and shouldn't need much tweaking beyond a rename.

### Query key parts/pieces are no longer automatically spread to the query function.

Inline functions are now the suggested way of passing parameters to your query functions:

```tsx
// Old
useQuery(['post', id], (_key, id) => fetchPost(id))

// New
useQuery(['post', id], () => fetchPost(id))
```

If you still insist on not using inline functions, you can use the newly passed `QueryFunctionContext`:

```tsx
useQuery(['post', id], (context) => fetchPost(context.queryKey[1]))
```

### Infinite Query Page params are now passed via `QueryFunctionContext.pageParam`

They were previously added as the last query key parameter in your query function, but this proved to be difficult for some patterns

```tsx
// Old
useInfiniteQuery(['posts'], (_key, pageParam = 0) => fetchPosts(pageParam))

// New
useInfiniteQuery(['posts'], ({ pageParam = 0 }) => fetchPosts(pageParam))
```

### usePaginatedQuery() has been removed in favor of the `keepPreviousData` option

The new `keepPreviousData` options is available for both `useQuery` and `useInfiniteQuery` and will have the same "lagging" effect on your data:

```tsx
import { useQuery } from 'react-query'

function Page({ page }) {
  const { data } = useQuery(['page', page], fetchPage, {
    keepPreviousData: true,
  })
}
```

### useInfiniteQuery() is now bi-directional

The `useInfiniteQuery()` interface has changed to fully support bi-directional infinite lists.

- `options.getFetchMore` has been renamed to `options.getNextPageParam`
- `queryResult.canFetchMore` has been renamed to `queryResult.hasNextPage`
- `queryResult.fetchMore` has been renamed to `queryResult.fetchNextPage`
- `queryResult.isFetchingMore` has been renamed to `queryResult.isFetchingNextPage`
- Added the `options.getPreviousPageParam` option
- Added the `queryResult.hasPreviousPage` property
- Added the `queryResult.fetchPreviousPage` property
- Added the `queryResult.isFetchingPreviousPage`
- The `data` of an infinite query is now an object containing the `pages` and the `pageParams` used to fetch the pages: `{ pages: [data, data, data], pageParams: [...]}`

One direction:

```tsx
const { data, fetchNextPage, hasNextPage, isFetchingNextPage } =
  useInfiniteQuery(
    'projects',
    ({ pageParam = 0 }) => fetchProjects(pageParam),
    {
      getNextPageParam: (lastPage, pages) => lastPage.nextCursor,
    },
  )
```

Both directions:

```tsx
const {
  data,
  fetchNextPage,
  fetchPreviousPage,
  hasNextPage,
  hasPreviousPage,
  isFetchingNextPage,
  isFetchingPreviousPage,
} = useInfiniteQuery(
  'projects',
  ({ pageParam = 0 }) => fetchProjects(pageParam),
  {
    getNextPageParam: (lastPage, pages) => lastPage.nextCursor,
    getPreviousPageParam: (firstPage, pages) => firstPage.prevCursor,
  },
)
```

One direction reversed:

```tsx
const { data, fetchNextPage, hasNextPage, isFetchingNextPage } =
  useInfiniteQuery(
    'projects',
    ({ pageParam = 0 }) => fetchProjects(pageParam),
    {
      select: (data) => ({
        pages: [...data.pages].reverse(),
        pageParams: [...data.pageParams].reverse(),
      }),
      getNextPageParam: (lastPage, pages) => lastPage.nextCursor,
    },
  )
```

### Infinite Query data now contains the array of pages and pageParams used to fetch those pages.

This allows for easier manipulation of the data and the page params, like, for example, removing the first page of data along with it's params:

```tsx
queryClient.setQueryData(['projects'], (data) => ({
  pages: data.pages.slice(1),
  pageParams: data.pageParams.slice(1),
}))
```

### useMutation now returns an object instead of an array

Though the old way gave us warm fuzzy feelings of when we first discovered `useState` for the first time, they didn't last long. Now the mutation return is a single object.

```tsx
// Old:
const [mutate, { status, reset }] = useMutation()

// New:
const { mutate, status, reset } = useMutation()
```

### `mutation.mutate` no longer return a promise

- The `[mutate]` variable has been changed to the `mutation.mutate` function
- Added the `mutation.mutateAsync` function

We got a lot of questions regarding this behavior as users expected the promise to behave like a regular promise.

Because of this the `mutate` function is now split into a `mutate` and `mutateAsync` function.

The `mutate` function can be used when using callbacks:

```tsx
const { mutate } = useMutation({ mutationFn: addTodo })

mutate('todo', {
  onSuccess: (data) => {
    console.log(data)
  },
  onError: (error) => {
    console.error(error)
  },
  onSettled: () => {
    console.log('settled')
  },
})
```

The `mutateAsync` function can be used when using async/await:

```tsx
const { mutateAsync } = useMutation({ mutationFn: addTodo })

try {
  const data = await mutateAsync('todo')
  console.log(data)
} catch (error) {
  console.error(error)
} finally {
  console.log('settled')
}
```

### The object syntax for useQuery now uses a collapsed config:

```tsx
// Old:
useQuery({
  queryKey: 'posts',
  queryFn: fetchPosts,
  config: { staleTime: Infinity },
})

// New:
useQuery({
  queryKey: 'posts',
  queryFn: fetchPosts,
  staleTime: Infinity,
})
```

### If set, the QueryOptions.enabled option must be a boolean (`true`/`false`)

The `enabled` query option will now only disable a query when the value is `false`.
If needed, values can be casted with `!!userId` or `Boolean(userId)` and a handy error will be thrown if a non-boolean value is passed.

### The QueryOptions.initialStale option has been removed

The `initialStale` query option has been removed and initial data is now treated as regular data.
Which means that if `initialData` is provided, the query will refetch on mount by default.
If you do not want to refetch immediately, you can define a `staleTime`.

### The `QueryOptions.forceFetchOnMount` option has been replaced by `refetchOnMount: 'always'`

Honestly, we were accruing way too many `refetchOn____` options, so this should clean things up.

### The `QueryOptions.refetchOnMount` options now only applies to its parent component instead of all query observers

When `refetchOnMount` was set to `false` any additional components were prevented from refetching on mount.
In version 3 only the component where the option has been set will not refetch on mount.

### The `QueryOptions.queryFnParamsFilter` has been removed in favor of the new `QueryFunctionContext` object.

The `queryFnParamsFilter` option has been removed because query functions now get a `QueryFunctionContext` object instead of the query key.

Parameters can still be filtered within the query function itself as the `QueryFunctionContext` also contains the query key.

### The `QueryOptions.notifyOnStatusChange` option has been superseded by the new `notifyOnChangeProps` and `notifyOnChangePropsExclusions` options.

With these new options it is possible to configure when a component should re-render on a granular level.

Only re-render when the `data` or `error` properties change:

```tsx
import { useQuery } from 'react-query'

function User() {
  const { data } = useQuery(['user'], fetchUser, {
    notifyOnChangeProps: ['data', 'error'],
  })
  return <div>Username: {data.username}</div>
}
```

Prevent re-render when the `isStale` property changes:

```tsx
import { useQuery } from 'react-query'

function User() {
  const { data } = useQuery(['user'], fetchUser, {
    notifyOnChangePropsExclusions: ['isStale'],
  })
  return <div>Username: {data.username}</div>
}
```

### The `QueryResult.clear()` function has been renamed to `QueryResult.remove()`

Although it was called `clear`, it really just removed the query from the cache. The name now matches the functionality.

### The `QueryResult.updatedAt` property has been split into `QueryResult.dataUpdatedAt` and `QueryResult.errorUpdatedAt` properties

Because data and errors can be present at the same time, the `updatedAt` property has been split into `dataUpdatedAt` and `errorUpdatedAt`.

### `setConsole()` has been replaced by the new `setLogger()` function

```tsx
import { setLogger } from 'react-query'

// Log with Sentry
setLogger({
  error: (error) => {
    Sentry.captureException(error)
  },
})

// Log with Winston
setLogger(winston.createLogger())
```

### React Native no longer requires overriding the logger

To prevent showing error screens in React Native when a query fails it was necessary to manually change the Console:

```tsx
import { setConsole } from 'react-query'

setConsole({
  log: console.log,
  warn: console.warn,
  error: console.warn,
})
```

In version 3 **this is done automatically when React Query is used in React Native**.

### Typescript

#### `QueryStatus` has been changed from an [enum](https://www.typescriptlang.org/docs/handbook/enums.html#string-enums) to a [union type](https://www.typescriptlang.org/docs/handbook/2/everyday-types.html#union-types)

So, if you were checking the status property of a query or mutation against a QueryStatus enum property you will have to check it now against the string literal the enum previously held for each property.

Therefore you have to change the enum properties to their equivalent string literal, like this:

- `QueryStatus.Idle` -> `'idle'`
- `QueryStatus.Loading` -> `'loading'`
- `QueryStatus.Error` -> `'error'`
- `QueryStatus.Success` -> `'success'`

Here is an example of the changes you would have to make:

```tsx
- import { useQuery, QueryStatus } from 'react-query'; // [!code --]
+ import { useQuery } from 'react-query'; // [!code ++]

const { data, status } = useQuery(['post', id], () => fetchPost(id))

- if (status === QueryStatus.Loading) { // [!code --]
+ if (status === 'loading') { // [!code ++]
  ...
}

- if (status === QueryStatus.Error) { // [!code --]
+ if (status === 'error') { // [!code ++]
  ...
}
```

## New features

#### Query Data Selectors

The `useQuery` and `useInfiniteQuery` hooks now have a `select` option to select or transform parts of the query result.

```tsx
import { useQuery } from 'react-query'

function User() {
  const { data } = useQuery(['user'], fetchUser, {
    select: (user) => user.username,
  })
  return <div>Username: {data}</div>
}
```

Set the `notifyOnChangeProps` option to `['data', 'error']` to only re-render when the selected data changes.

#### The useQueries() hook, for variable-length parallel query execution

Wish you could run `useQuery` in a loop? The rules of hooks say no, but with the new `useQueries()` hook, you can!

```tsx
import { useQueries } from 'react-query'

function Overview() {
  const results = useQueries([
    { queryKey: ['post', 1], queryFn: fetchPost },
    { queryKey: ['post', 2], queryFn: fetchPost },
  ])
  return (
    <ul>
      {results.map(({ data }) => data && <li key={data.id}>{data.title})</li>)}
    </ul>
  )
}
```

#### Retry/offline mutations

By default React Query will not retry a mutation on error, but it is possible with the `retry` option:

```tsx
const mutation = useMutation({
  mutationFn: addTodo,
  retry: 3,
})
```

If mutations fail because the device is offline, they will be retried in the same order when the device reconnects.

#### Persist mutations

Mutations can now be persisted to storage and resumed at a later point. More information can be found in the mutations documentation.

#### QueryObserver

A `QueryObserver` can be used to create and/or watch a query:

```tsx
const observer = new QueryObserver(queryClient, { queryKey: 'posts' })

const unsubscribe = observer.subscribe((result) => {
  console.log(result)
  unsubscribe()
})
```

#### InfiniteQueryObserver

A `InfiniteQueryObserver` can be used to create and/or watch an infinite query:

```tsx
const observer = new InfiniteQueryObserver(queryClient, {
  queryKey: 'posts',
  queryFn: fetchPosts,
  getNextPageParam: (lastPage, allPages) => lastPage.nextCursor,
  getPreviousPageParam: (firstPage, allPages) => firstPage.prevCursor,
})

const unsubscribe = observer.subscribe((result) => {
  console.log(result)
  unsubscribe()
})
```

#### QueriesObserver

A `QueriesObserver` can be used to create and/or watch multiple queries:

```tsx
const observer = new QueriesObserver(queryClient, [
  { queryKey: ['post', 1], queryFn: fetchPost },
  { queryKey: ['post', 2], queryFn: fetchPost },
])

const unsubscribe = observer.subscribe((result) => {
  console.log(result)
  unsubscribe()
})
```

#### Set default options for specific queries

The `QueryClient.setQueryDefaults()` method can be used to set default options for specific queries:

```tsx
queryClient.setQueryDefaults(['posts'], { queryFn: fetchPosts })

function Component() {
  const { data } = useQuery(['posts'])
}
```

#### Set default options for specific mutations

The `QueryClient.setMutationDefaults()` method can be used to set default options for specific mutations:

```tsx
queryClient.setMutationDefaults(['addPost'], { mutationFn: addPost })

function Component() {
  const { mutate } = useMutation({ mutationKey: ['addPost'] })
}
```

#### useIsFetching()

The `useIsFetching()` hook now accepts filters which can be used to for example only show a spinner for certain type of queries:

```tsx
const fetches = useIsFetching({ queryKey: ['posts'] })
```

#### Core separation

The core of React Query is now fully separated from React, which means it can also be used standalone or in other frameworks. Use the `react-query/core` entry point to only import the core functionality:

```tsx
import { QueryClient } from 'react-query/core'
```

### Devtools are now part of the main repo and npm package

The devtools are now included in the `react-query` package itself under the import `react-query/devtools`. Simply replace `react-query-devtools` imports with `react-query/devtools`

---

# migrating-to-react-query-4


---
id: migrating-to-react-query-4
title: Migrating to React Query 4
---

## Breaking Changes

v4 is a major version, so there are some breaking changes to be aware of:

### react-query is now @tanstack/react-query

You will need to un-/install dependencies and change the imports:

```
npm uninstall react-query
npm install @tanstack/react-query
npm install @tanstack/react-query-devtools
```

```tsx
- import { useQuery } from 'react-query' // [!code --]
- import { ReactQueryDevtools } from 'react-query/devtools' // [!code --]

+ import { useQuery } from '@tanstack/react-query' // [!code ++]
+ import { ReactQueryDevtools } from '@tanstack/react-query-devtools' // [!code ++]
```

#### Codemod

To make the import migration easier, v4 comes with a codemod.

> The codemod is a best efforts attempt to help you migrate the breaking change. Please review the generated code thoroughly! Also, there are edge cases that cannot be found by the code mod, so please keep an eye on the log output.

You can easily apply it by using one (or both) of the following commands:

If you want to run it against `.js` or `.jsx` files, please use the command below:

```
npx jscodeshift ./path/to/src/ \
  --extensions=js,jsx \
  --transform=./node_modules/@tanstack/react-query/codemods/v4/replace-import-specifier.js
```

If you want to run it against `.ts` or `.tsx` files, please use the command below:

```
npx jscodeshift ./path/to/src/ \
  --extensions=ts,tsx \
  --parser=tsx \
  --transform=./node_modules/@tanstack/react-query/codemods/v4/replace-import-specifier.js
```

Please note in the case of `TypeScript` you need to use `tsx` as the parser; otherwise, the codemod won't be applied properly!

**Note:** Applying the codemod might break your code formatting, so please don't forget to run `prettier` and/or `eslint` after you've applied the codemod!

**Note:** The codemod will _only_ change the imports - you still have to install the separate devtools package manually.

### Query Keys (and Mutation Keys) need to be an Array

In v3, Query and Mutation Keys could be a String or an Array. Internally, React Query has always worked with Array Keys only, and we've sometimes exposed this to consumers. For example, in the `queryFn`, you would always get the key as an Array to make working with [Default Query Functions](../default-query-function) easier.

However, we have not followed this concept through to all apis. For example, when using the `predicate` function on [Query Filters](../filters) you would get the raw Query Key. This makes it difficult to work with such functions if you use Query Keys that are mixed Arrays and Strings. The same was true when using global callbacks.

To streamline all apis, we've decided to make all keys Arrays only:

```tsx
;-useQuery('todos', fetchTodos) + // [!code --]
  useQuery(['todos'], fetchTodos) // [!code ++]
```

#### Codemod

To make this migration easier, we decided to deliver a codemod.

> The codemod is a best efforts attempt to help you migrate the breaking change. Please review the generated code thoroughly! Also, there are edge cases that cannot be found by the code mod, so please keep an eye on the log output.

You can easily apply it by using one (or both) of the following commands:

If you want to run it against `.js` or `.jsx` files, please use the command below:

```
npx jscodeshift ./path/to/src/ \
  --extensions=js,jsx \
  --transform=./node_modules/@tanstack/react-query/codemods/v4/key-transformation.js
```

If you want to run it against `.ts` or `.tsx` files, please use the command below:

```
npx jscodeshift ./path/to/src/ \
  --extensions=ts,tsx \
  --parser=tsx \
  --transform=./node_modules/@tanstack/react-query/codemods/v4/key-transformation.js
```

Please note in the case of `TypeScript` you need to use `tsx` as the parser; otherwise, the codemod won't be applied properly!

**Note:** Applying the codemod might break your code formatting, so please don't forget to run `prettier` and/or `eslint` after you've applied the codemod!

### The idle state has been removed

With the introduction of the new [fetchStatus](../queries#fetchstatus) for better offline support, the `idle` state became irrelevant, because `fetchStatus: 'idle'` captures the same state better. For more information, please read [Why two different states](../queries#why-two-different-states).

This will mostly affect `disabled` queries that don't have any `data` yet, as those were in `idle` state before:

```tsx
- status: 'idle' // [!code --]
+ status: 'loading'  // [!code ++]
+ fetchStatus: 'idle' // [!code ++]
```

Also, have a look at [the guide on dependent queries](../dependent-queries)

#### disabled queries

Due to this change, disabled queries (even temporarily disabled ones) will start in `loading` state. To make migration easier, especially for having a good flag to know when to display a loading spinner, you can check for `isInitialLoading` instead of `isLoading`:

```tsx
;-isLoading + // [!code --]
  isInitialLoading // [!code ++]
```

See also the guide on [disabling queries](../disabling-queries#isInitialLoading)

### new API for `useQueries`

The `useQueries` hook now accepts an object with a `queries` prop as its input. The value of the `queries` prop is an array of queries (this array is identical to what was passed into `useQueries` in v3).

```tsx
;-useQueries([
  { queryKey1, queryFn1, options1 },
  { queryKey2, queryFn2, options2 },
]) + // [!code --]
  useQueries({
    queries: [
      { queryKey1, queryFn1, options1 },
      { queryKey2, queryFn2, options2 },
    ],
  }) // [!code ++]
```

### Undefined is an illegal cache value for successful queries

In order to make bailing out of updates possible by returning `undefined`, we had to make `undefined` an illegal cache value. This is in-line with other concepts of react-query, for example, returning `undefined` from the [initialData function](../initial-query-data#initial-data-function) will also _not_ set data.

Further, it is an easy bug to produce `Promise<void>` by adding logging in the queryFn:

```tsx
useQuery(['key'], () =>
  axios.get(url).then((result) => console.log(result.data)),
)
```

This is now disallowed on type level; at runtime, `undefined` will be transformed to a _failed Promise_, which means you will get an `error`, which will also be logged to the console in development mode.

### Queries and mutations, per default, need network connection to run

Please read the [New Features announcement](#proper-offline-support) about online / offline support, and also the dedicated page about [Network mode](../network-mode)

Even though React Query is an Async State Manager that can be used for anything that produces a Promise, it is most often used for data fetching in combination with data fetching libraries. That is why, per default, queries and mutations will be `paused` if there is no network connection. If you want to opt-in to the previous behavior, you can globally set `networkMode: offlineFirst` for both queries and mutations:

```tsx
new QueryClient({
  defaultOptions: {
    queries: {
      networkMode: 'offlineFirst',
    },
    mutations: {
      networkMode: 'offlineFirst',
    },
  },
})
```

### `notifyOnChangeProps` property no longer accepts `"tracked"` as a value

The `notifyOnChangeProps` option no longer accepts a `"tracked"` value. Instead, `useQuery` defaults to tracking properties. All queries using `notifyOnChangeProps: "tracked"` should be updated by removing this option.

If you would like to bypass this in any queries to emulate the v3 default behavior of re-rendering whenever a query changes, `notifyOnChangeProps` now accepts an `"all"` value to opt-out of the default smart tracking optimization.

### `notifyOnChangePropsExclusion` has been removed

In v4, `notifyOnChangeProps` defaults to the `"tracked"` behavior of v3 instead of `undefined`. Now that `"tracked"` is the default behavior for v4, it no longer makes sense to include this config option.

### Consistent behavior for `cancelRefetch`

The `cancelRefetch` option can be passed to all functions that imperatively fetch a query, namely:

- `queryClient.refetchQueries`
- `queryClient.invalidateQueries`
- `queryClient.resetQueries`
- `refetch` returned from `useQuery`
- `fetchNextPage` and `fetchPreviousPage` returned from `useInfiniteQuery`

Except for `fetchNextPage` and `fetchPreviousPage`, this flag was defaulting to `false`, which was inconsistent and potentially troublesome: Calling `refetchQueries` or `invalidateQueries` after a mutation might not yield the latest result if a previous slow fetch was already ongoing, because this refetch would have been skipped.

We believe that if a query is actively refetched by some code you write, it should, per default, re-start the fetch.

That is why this flag now defaults to _true_ for all methods mentioned above. It also means that if you call `refetchQueries` twice in a row, without awaiting it, it will now cancel the first fetch and re-start it with the second one:

```
queryClient.refetchQueries({ queryKey: ['todos'] })
// this will abort the previous refetch and start a new fetch
queryClient.refetchQueries({ queryKey: ['todos'] })
```

You can opt-out of this behaviour by explicitly passing `cancelRefetch:false`:

```
queryClient.refetchQueries({ queryKey: ['todos'] })
// this will not abort the previous refetch - it will just be ignored
queryClient.refetchQueries({ queryKey: ['todos'] }, { cancelRefetch: false })
```

> Note: There is no change in behaviour for automatically triggered fetches, e.g. because a query mounts or because of a window focus refetch.

### Query Filters

A [query filter](../filters) is an object with certain conditions to match a query. Historically, the filter options have mostly been a combination of boolean flags. However, combining those flags can lead to impossible states. Specifically:

```
active?: boolean
  - When set to true it will match active queries.
  - When set to false it will match inactive queries.
inactive?: boolean
  - When set to true it will match inactive queries.
  - When set to false it will match active queries.
```

Those flags don't work well when used together, because they are mutually exclusive. Setting `false` for both flags could match all queries, judging from the description, or no queries, which doesn't make much sense.

With v4, those filters have been combined into a single filter to better show the intent:

```tsx
- active?: boolean // [!code --]
- inactive?: boolean // [!code --]
+ type?: 'active' | 'inactive' | 'all' // [!code ++]
```

The filter defaults to `all`, and you can choose to only match `active` or `inactive` queries.

#### refetchActive / refetchInactive

[queryClient.invalidateQueries](../../../../reference/QueryClient/#queryclientinvalidatequeries) had two additional, similar flags:

```
refetchActive: Boolean
  - Defaults to true
  - When set to false, queries that match the refetch predicate and are actively being rendered
    via useQuery and friends will NOT be refetched in the background, and only marked as invalid.
refetchInactive: Boolean
  - Defaults to false
  - When set to true, queries that match the refetch predicate and are not being rendered
    via useQuery and friends will be both marked as invalid and also refetched in the background
```

For the same reason, those have also been combined:

```tsx
- refetchActive?: boolean // [!code --]
- refetchInactive?: boolean // [!code --]
+ refetchType?: 'active' | 'inactive' | 'all' | 'none' // [!code ++]
```

This flag defaults to `active` because `refetchActive` defaulted to `true`. This means we also need a way to tell `invalidateQueries` to not refetch at all, which is why a fourth option (`none`) is also allowed here.

### `onSuccess` is no longer called from `setQueryData`

This was confusing to many and also created infinite loops if `setQueryData` was called from within `onSuccess`. It was also a frequent source of error when combined with `staleTime`, because if data was read from the cache only, `onSuccess` was _not_ called.

Similar to `onError` and `onSettled`, the `onSuccess` callback is now tied to a request being made. No request -> no callback.

If you want to listen to changes of the `data` field, you can best do this with a `useEffect`, where `data` is part of the dependency Array. Since React Query ensures stable data through structural sharing, the effect will not execute with every background refetch, but only if something within data has changed:

```
const { data } = useQuery({ queryKey, queryFn })
React.useEffect(() => mySideEffectHere(data), [data])
```

### `persistQueryClient` and the corresponding persister plugins are no longer experimental and have been renamed

The plugins `createWebStoragePersistor` and `createAsyncStoragePersistor` have been renamed to [`createSyncStoragePersister`](../../plugins/createSyncStoragePersister) and [`createAsyncStoragePersister`](../../plugins/createAsyncStoragePersister) respectively. The interface `Persistor` in `persistQueryClient` has also been renamed to `Persister`. Checkout [this stackexchange](https://english.stackexchange.com/questions/206893/persister-or-persistor) for the motivation of this change.

Since these plugins are no longer experimental, their import paths have also been updated:

```tsx
- import { persistQueryClient } from 'react-query/persistQueryClient-experimental' // [!code --]
- import { createWebStoragePersistor } from 'react-query/createWebStoragePersistor-experimental' // [!code --]
- import { createAsyncStoragePersistor } from 'react-query/createAsyncStoragePersistor-experimental' // [!code --]

+ import { persistQueryClient } from '@tanstack/react-query-persist-client' // [!code ++]
+ import { createSyncStoragePersister } from '@tanstack/query-sync-storage-persister' // [!code ++]
+ import { createAsyncStoragePersister } from '@tanstack/query-async-storage-persister'  // [!code ++]
```

### The `cancel` method on promises is no longer supported

The [old `cancel` method](../query-cancellation#old-cancel-function) that allowed you to define a `cancel` function on promises, which was then used by the library to support query cancellation, has been removed. We recommend to use the [newer API](../query-cancellation) (introduced with v3.30.0) for query cancellation that uses the [`AbortController` API](https://developer.mozilla.org/en-US/docs/Web/API/AbortController) internally and provides you with an [`AbortSignal` instance](https://developer.mozilla.org/en-US/docs/Web/API/AbortSignal) for your query function to support query cancellation.

### TypeScript

Types now require using TypeScript v4.1 or greater

### Supported Browsers

As of v4, React Query is optimized for modern browsers. We have updated our browserslist to produce a more modern, performant and smaller bundle. You can read about the requirements [here](../../installation#requirements).

### `setLogger` is removed

It was possible to change the logger globally by calling `setLogger`. In v4, that function is replaced with an optional field when creating a `QueryClient`.

```tsx
- import { QueryClient, setLogger } from 'react-query'; // [!code --]
+ import { QueryClient } from '@tanstack/react-query'; // [!code ++]

- setLogger(customLogger) // [!code --]
- const queryClient = new QueryClient(); // [!code --]
+ const queryClient = new QueryClient({ logger: customLogger }) // [!code ++]
```

### No _default_ manual Garbage Collection server-side

In v3, React Query would cache query results for a default of 5 minutes, then manually garbage collect that data. This default was applied to server-side React Query as well.

This lead to high memory consumption and hanging processes waiting for this manual garbage collection to complete. In v4, by default the server-side `cacheTime` is now set to `Infinity` effectively disabling manual garbage collection (the NodeJS process will clear everything once a request is complete).

This change only impacts users of server-side React Query, such as with Next.js. If you are setting a `cacheTime` manually this will not impact you (although you may want to mirror behavior).

### Logging in production

Starting with v4, react-query will no longer log errors (e.g. failed fetches) to the console in production mode, as this was confusing to many.
Errors will still show up in development mode.

### ESM Support

React Query now supports [package.json `"exports"`](https://nodejs.org/api/packages.html#exports) and is fully compatible with Node's native resolution for both CommonJS and ESM. We don't expect this to be a breaking change for most users, but this restricts the files you can import into your project to only the entry points we officially support.

### Streamlined NotifyEvents

Subscribing manually to the `QueryCache` has always given you a `QueryCacheNotifyEvent`, but this was not true for the `MutationCache`. We have streamlined the behavior and also adapted event names accordingly.

#### QueryCacheNotifyEvent

```tsx
- type: 'queryAdded' // [!code --]
+ type: 'added' // [!code ++]
- type: 'queryRemoved' // [!code --]
+ type: 'removed' // [!code ++]
- type: 'queryUpdated' // [!code --]
+ type: 'updated' // [!code ++]
```

#### MutationCacheNotifyEvent

The `MutationCacheNotifyEvent` uses the same types as the `QueryCacheNotifyEvent`.

> Note: This is only relevant if you manually subscribe to the caches via `queryCache.subscribe` or `mutationCache.subscribe`

### Separate hydration exports have been removed

With version [3.22.0](https://github.com/tannerlinsley/react-query/releases/tag/v3.22.0), hydration utilities moved into the React Query core. With v3, you could still use the old exports from `react-query/hydration`, but these exports have been removed with v4.

```tsx
- import { dehydrate, hydrate, useHydrate, Hydrate } from 'react-query/hydration' // [!code --]
+ import { dehydrate, hydrate, useHydrate, Hydrate } from '@tanstack/react-query' // [!code ++]
```

### Removed undocumented methods from the `queryClient`, `query` and `mutation`

The methods `cancelMutatations` and `executeMutation` on the `QueryClient` were undocumented and unused internally, so we removed them. Since it was just a wrapper around a method available on the `mutationCache`, you can still use the functionality of `executeMutation`

```tsx
- executeMutation< // [!code --]
-   TData = unknown, // [!code --]
-   TError = unknown, // [!code --]
-   TVariables = void, // [!code --]
-   TContext = unknown // [!code --]
- >( // [!code --]
-   options: MutationOptions<TData, TError, TVariables, TContext> // [!code --]
- ): Promise<TData> { // [!code --]
-   return this.mutationCache.build(this, options).execute() // [!code --]
- } // [!code --]
```

Additionally, `query.setDefaultOptions` was removed because it was also unused. `mutation.cancel` was removed because it didn't actually cancel the outgoing request.

### The `src/react` directory was renamed to `src/reactjs`

Previously, React Query had a directory named `react` which imported from the `react` module. This could cause problems with some Jest configurations, resulting in errors when running tests like:

```
TypeError: Cannot read property 'createContext' of undefined
```

With the renamed directory this no longer is an issue.

If you were importing anything from `'react-query/react'` directly in your project (as opposed to just `'react-query'`), then you need to update your imports:

```tsx
- import { QueryClientProvider } from 'react-query/react'; // [!code --]
+ import { QueryClientProvider } from '@tanstack/react-query/reactjs'; // [!code ++]
```

## New Features 🚀

v4 comes with an awesome set of new features:

### Support for React 18

React 18 was released earlier this year, and v4 now has first class support for it and the new concurrent features it brings.

### Proper offline support

In v3, React Query has always fired off queries and mutations, but then taken the assumption that if you want to retry it, you need to be connected to the internet. This has led to several confusing situations:

- You are offline and mount a query - it goes to loading state, the request fails, and it stays in loading state until you go online again, even though it is not really fetching.
- Similarly, if you are offline and have retries turned off, your query will just fire and fail, and the query goes to error state.
- You are offline and want to fire off a query that doesn't necessarily need network connection (because you _can_ use React Query for something other than data fetching), but it fails for some other reason. That query will now be paused until you go online again.
- Window focus refetching didn't do anything at all if you were offline.

With v4, React Query introduces a new `networkMode` to tackle all these issues. Please read the dedicated page about the new [Network mode](../network-mode) for more information.

### Tracked Queries per default

React Query defaults to "tracking" query properties, which should give you a nice boost in render optimization. The feature has existed since [v3.6.0](https://github.com/tannerlinsley/react-query/releases/tag/v3.6.0) and has now become the default behavior with v4.

### Bailing out of updates with setQueryData

When using the [functional updater form of setQueryData](../../../../reference/QueryClient/#queryclientsetquerydata), you can now bail out of the update by returning `undefined`. This is helpful if `undefined` is given to you as `previousValue`, which means that currently, no cached entry exists and you don't want to / cannot create one, like in the example of toggling a todo:

```tsx
queryClient.setQueryData(['todo', id], (previousTodo) =>
  previousTodo ? { ...previousTodo, done: true } : undefined,
)
```

### Mutation Cache Garbage Collection

Mutations can now also be garbage collected automatically, just like queries. The default `cacheTime` for mutations is also set to 5 minutes.

### Custom Contexts for Multiple Providers

Custom contexts can now be specified to pair hooks with their matching `Provider`. This is critical when there may be multiple React Query `Provider` instances in the component tree, and you need to ensure your hook uses the correct `Provider` instance.

An example:

1. Create a data package.

```tsx
// Our first data package: @my-scope/container-data

const context = React.createContext<QueryClient | undefined>(undefined)
const queryClient = new QueryClient()

export const useUser = () => {
  return useQuery(USER_KEY, USER_FETCHER, {
    context,
  })
}

export const ContainerDataProvider = ({
  children,
}: {
  children: React.ReactNode
}) => {
  return (
    <QueryClientProvider client={queryClient} context={context}>
      {children}
    </QueryClientProvider>
  )
}
```

2. Create a second data package.

```tsx
// Our second data package: @my-scope/my-component-data

const context = React.createContext<QueryClient | undefined>(undefined)
const queryClient = new QueryClient()

export const useItems = () => {
  return useQuery(ITEMS_KEY, ITEMS_FETCHER, {
    context,
  })
}

export const MyComponentDataProvider = ({
  children,
}: {
  children: React.ReactNode
}) => {
  return (
    <QueryClientProvider client={queryClient} context={context}>
      {children}
    </QueryClientProvider>
  )
}
```

3. Use these two data packages in your application.

```tsx
// Our application

import { ContainerDataProvider, useUser } from "@my-scope/container-data";
import { AppDataProvider } from "@my-scope/app-data";
import { MyComponentDataProvider, useItems } from "@my-scope/my-component-data";

<ContainerDataProvider> // <-- Provides container data (like "user") using its own React Query provider
  ...
  <AppDataProvider> // <-- Provides app data using its own React Query provider (unused in this example)
    ...
      <MyComponentDataProvider> // <-- Provides component data (like "items") using its own React Query provider
        <MyComponent />
      </MyComponentDataProvider>
    ...
  </AppDataProvider>
  ...
</ContainerDataProvider>

// Example of hooks provided by the "DataProvider" components above:
const MyComponent = () => {
  const user = useUser() // <-- Uses the context specified in ContainerDataProvider.
  const items = useItems() // <-- Uses the context specified in MyComponentDataProvider
  ...
}
```

---

# migrating-to-v5


---
id: migrating-to-tanstack-query-5
title: Migrating to TanStack Query v5
---

## Breaking Changes

v5 is a major version, so there are some breaking changes to be aware of:

### Supports a single signature, one object

useQuery and friends used to have many overloads in TypeScript - different ways how the function can be invoked. Not only this was tough to maintain, type wise, it also required a runtime check to see which type the first and the second parameter, to correctly create options.

now we only support the object format.

```tsx
;-useQuery(key, fn, options) + // [!code --]
  useQuery({ queryKey, queryFn, ...options }) - // [!code ++]
  useInfiniteQuery(key, fn, options) + // [!code --]
  useInfiniteQuery({ queryKey, queryFn, ...options }) - // [!code ++]
  useMutation(fn, options) + // [!code --]
  useMutation({ mutationFn, ...options }) - // [!code ++]
  useIsFetching(key, filters) + // [!code --]
  useIsFetching({ queryKey, ...filters }) - // [!code ++]
  useIsMutating(key, filters) + // [!code --]
  useIsMutating({ mutationKey, ...filters }) // [!code ++]
```

```tsx
;-queryClient.isFetching(key, filters) + // [!code --]
  queryClient.isFetching({ queryKey, ...filters }) - // [!code ++]
  queryClient.ensureQueryData(key, filters) + // [!code --]
  queryClient.ensureQueryData({ queryKey, ...filters }) - // [!code ++]
  queryClient.getQueriesData(key, filters) + // [!code --]
  queryClient.getQueriesData({ queryKey, ...filters }) - // [!code ++]
  queryClient.setQueriesData(key, updater, filters, options) + // [!code --]
  queryClient.setQueriesData({ queryKey, ...filters }, updater, options) - // [!code ++]
  queryClient.removeQueries(key, filters) + // [!code --]
  queryClient.removeQueries({ queryKey, ...filters }) - // [!code ++]
  queryClient.resetQueries(key, filters, options) + // [!code --]
  queryClient.resetQueries({ queryKey, ...filters }, options) - // [!code ++]
  queryClient.cancelQueries(key, filters, options) + // [!code --]
  queryClient.cancelQueries({ queryKey, ...filters }, options) - // [!code ++]
  queryClient.invalidateQueries(key, filters, options) + // [!code --]
  queryClient.invalidateQueries({ queryKey, ...filters }, options) - // [!code ++]
  queryClient.refetchQueries(key, filters, options) + // [!code --]
  queryClient.refetchQueries({ queryKey, ...filters }, options) - // [!code ++]
  queryClient.fetchQuery(key, fn, options) + // [!code --]
  queryClient.fetchQuery({ queryKey, queryFn, ...options }) - // [!code ++]
  queryClient.prefetchQuery(key, fn, options) + // [!code --]
  queryClient.prefetchQuery({ queryKey, queryFn, ...options }) - // [!code ++]
  queryClient.fetchInfiniteQuery(key, fn, options) + // [!code --]
  queryClient.fetchInfiniteQuery({ queryKey, queryFn, ...options }) - // [!code ++]
  queryClient.prefetchInfiniteQuery(key, fn, options) + // [!code --]
  queryClient.prefetchInfiniteQuery({ queryKey, queryFn, ...options }) // [!code ++]
```

```tsx
;-queryCache.find(key, filters) + // [!code --]
  queryCache.find({ queryKey, ...filters }) - // [!code ++]
  queryCache.findAll(key, filters) + // [!code --]
  queryCache.findAll({ queryKey, ...filters }) // [!code ++]
```

### `queryClient.getQueryData` now accepts queryKey only as an Argument

`queryClient.getQueryData` argument is changed to accept only a `queryKey`

```tsx
;-queryClient.getQueryData(queryKey, filters) + // [!code --]
  queryClient.getQueryData(queryKey) // [!code ++]
```

### `queryClient.getQueryState` now accepts queryKey only as an Argument

`queryClient.getQueryState` argument is changed to accept only a `queryKey`

```tsx
;-queryClient.getQueryState(queryKey, filters) + // [!code --]
  queryClient.getQueryState(queryKey) // [!code ++]
```

#### Codemod

To make the remove overloads migration easier, v5 comes with a codemod.

> The codemod is a best efforts attempt to help you migrate the breaking change. Please review the generated code thoroughly! Also, there are edge cases that cannot be found by the code mod, so please keep an eye on the log output.

If you want to run it against `.js` or `.jsx` files, please use the command below:

```
npx jscodeshift@latest ./path/to/src/ \
  --extensions=js,jsx \
  --transform=./node_modules/@tanstack/react-query/build/codemods/src/v5/remove-overloads/remove-overloads.cjs
```

If you want to run it against `.ts` or `.tsx` files, please use the command below:

```
npx jscodeshift@latest ./path/to/src/ \
  --extensions=ts,tsx \
  --parser=tsx \
  --transform=./node_modules/@tanstack/react-query/build/codemods/src/v5/remove-overloads/remove-overloads.cjs
```

Please note in the case of `TypeScript` you need to use `tsx` as the parser; otherwise, the codemod won't be applied properly!

**Note:** Applying the codemod might break your code formatting, so please don't forget to run `prettier` and/or `eslint` after you've applied the codemod!

A few notes about how codemod works:

- Generally, we're looking for the lucky case, when the first parameter is an object expression and contains the "queryKey" or "mutationKey" property (depending on which hook/method call is being transformed). If this is the case, your code already matches the new signature, so the codemod won't touch it. 🎉
- If the condition above is not fulfilled, then the codemod will check whether the first parameter is an array expression or an identifier that references an array expression. If this is the case, the codemod will put it into an object expression, then it will be the first parameter.
- If object parameters can be inferred, the codemod will attempt to copy the already existing properties to the newly created one.
- If the codemod cannot infer the usage, then it will leave a message on the console. The message contains the file name and the line number of the usage. In this case, you need to do the migration manually.
- If the transformation results in an error, you will also see a message on the console. This message will notify you something unexpected happened, please do the migration manually.

### Callbacks on useQuery (and QueryObserver) have been removed

`onSuccess`, `onError` and `onSettled` have been removed from Queries. They haven't been touched for Mutations. Please see [this RFC](https://github.com/TanStack/query/discussions/5279) for motivations behind this change and what to do instead.

### The `refetchInterval` callback function only gets `query` passed

This streamlines how callbacks are invoked (the `refetchOnWindowFocus`, `refetchOnMount` and `refetchOnReconnect` callbacks all only get the query passed as well), and it fixes some typing issues when callbacks get data transformed by `select`.

```tsx
- refetchInterval: number | false | ((data: TData | undefined, query: Query) => number | false | undefined) // [!code --]
+ refetchInterval: number | false | ((query: Query) => number | false | undefined) // [!code ++]
```

You can still access data with `query.state.data`, however, it will not be data that has been transformed by `select`. If you need to access the transformed data, you can call the transformation again on `query.state.data`.

### The `remove` method has been removed from useQuery

Previously, remove method used to remove the query from the queryCache without informing observers about it. It was best used to remove data imperatively that is no longer needed, e.g. when logging a user out.

But It doesn't make much sense to do this while a query is still active, because it will just trigger a hard loading state with the next re-render.

if you still need to remove a query, you can use `queryClient.removeQueries({queryKey: key})`

```tsx
const queryClient = useQueryClient()
const query = useQuery({ queryKey, queryFn })

;-query.remove() + // [!code --]
  queryClient.removeQueries({ queryKey }) // [!code ++]
```

### The minimum required TypeScript version is now 4.7

Mainly because an important fix was shipped around type inference. Please see this [TypeScript issue](https://github.com/microsoft/TypeScript/issues/43371) for more information.

### The `isDataEqual` option has been removed from useQuery

Previously, This function was used to indicate whether to use previous `data` (`true`) or new data (`false`) as a resolved data for the query.

You can achieve the same functionality by passing a function to `structuralSharing` instead:

```tsx
 import { replaceEqualDeep } from '@tanstack/react-query'

- isDataEqual: (oldData, newData) => customCheck(oldData, newData) // [!code --]
+ structuralSharing: (oldData, newData) => customCheck(oldData, newData) ? oldData : replaceEqualDeep(oldData, newData) // [!code ++]
```

### The deprecated custom logger has been removed

Custom loggers were already deprecated in 4 and have been removed in this version. Logging only had an effect in development mode, where passing a custom logger is not necessary.

### Supported Browsers

We have updated our browserslist to produce a more modern, performant and smaller bundle. You can read about the requirements [here](../../installation#requirements).

### Private class fields and methods

TanStack Query has always had private fields and methods on classes, but they weren't really private - they were just private in `TypeScript`. We now use [ECMAScript Private class features](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Classes/Private_class_fields), which means those fields are now truly private and can't be accessed from the outside at runtime.

### Rename `cacheTime` to `gcTime`

Almost everyone gets `cacheTime` wrong. It sounds like "the amount of time that data is cached for", but that is not correct.

`cacheTime` does nothing as long as a query is still in use. It only kicks in as soon as the query becomes unused. After the time has passed, data will be "garbage collected" to avoid the cache from growing.

`gc` is referring to "garbage collect" time. It's a bit more technical, but also a quite [well known abbreviation](<https://en.wikipedia.org/wiki/Garbage_collection_(computer_science)>) in computer science.

```tsx
const MINUTE = 1000 * 60;

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
-      cacheTime: 10 * MINUTE, // [!code --]
+      gcTime: 10 * MINUTE, // [!code ++]
    },
  },
})
```

### The `useErrorBoundary` option has been renamed to `throwOnError`

To make the `useErrorBoundary` option more framework-agnostic and avoid confusion with the established React function prefix "`use`" for hooks and the "ErrorBoundary" component name, it has been renamed to `throwOnError` to more accurately reflect its functionality.

### TypeScript: `Error` is now the default type for errors instead of `unknown`

Even though in JavaScript, you can `throw` anything (which makes `unknown` the most correct type), almost always, `Errors` (or subclasses of `Error`) are thrown. This change makes it easier to work with the `error` field in TypeScript for most cases.

If you want to throw something that isn't an Error, you'll now have to set the generic for yourself:

```ts
useQuery<number, string>({
  queryKey: ['some-query'],
  queryFn: async () => {
    if (Math.random() > 0.5) {
      throw 'some error'
    }
    return 42
  },
})
```

For a way to set a different kind of Error globally, see [the TypeScript Guide](../../typescript#registering-a-global-error).

### eslint `prefer-query-object-syntax` rule is removed

Since the only supported syntax now is the object syntax, this rule is no longer needed

### Removed `keepPreviousData` in favor of `placeholderData` identity function

We have removed the `keepPreviousData` option and `isPreviousData` flag as they were doing mostly the same thing as `placeholderData` and `isPlaceholderData` flag.

To achieve the same functionality as `keepPreviousData`, we have added previous query `data` as an argument to `placeholderData` which accepts an identity function. Therefore you just need to provide an identity function to `placeholderData` or use the included `keepPreviousData` function from Tanstack Query.

> A note here is that `useQueries` would not receive `previousData` in the `placeholderData` function as argument. This is due to a dynamic nature of queries passed in the array, which may lead to a different shape of result from placeholder and queryFn.

```tsx
import {
   useQuery,
+  keepPreviousData // [!code ++]
} from "@tanstack/react-query";

const {
   data,
-  isPreviousData, // [!code --]
+  isPlaceholderData, // [!code ++]
} = useQuery({
  queryKey,
  queryFn,
- keepPreviousData: true, // [!code --]
+ placeholderData: keepPreviousData // [!code ++]
});
```

An identity function, in the context of Tanstack Query, refers to a function that always returns its provided argument (i.e. data) unchanged.

```ts
useQuery({
  queryKey,
  queryFn,
  placeholderData: (previousData, previousQuery) => previousData, // identity function with the same behaviour as `keepPreviousData`
})
```

There are some caveats to this change however, which you must be aware of:

- `placeholderData` will always put you into `success` state, while `keepPreviousData` gave you the status of the previous query. That status could be `error` if we have data fetched successfully and then got a background refetch error. However, the error itself was not shared, so we decided to stick with behavior of `placeholderData`.
- `keepPreviousData` gave you the `dataUpdatedAt` timestamp of the previous data, while with `placeholderData`, `dataUpdatedAt` will stay at `0`. This might be annoying if you want to show that timestamp continuously on screen. However you might get around it with `useEffect`.

  ```ts
  const [updatedAt, setUpdatedAt] = useState(0)

  const { data, dataUpdatedAt } = useQuery({
    queryKey: ['projects', page],
    queryFn: () => fetchProjects(page),
  })

  useEffect(() => {
    if (dataUpdatedAt > updatedAt) {
      setUpdatedAt(dataUpdatedAt)
    }
  }, [dataUpdatedAt])
  ```

### Window focus refetching no longer listens to the `focus` event

The `visibilitychange` event is used exclusively now. This is possible because we only support browsers that support the `visibilitychange` event. This fixes a bunch of issues [as listed here](https://github.com/TanStack/query/pull/4805).

### Network status no longer relies on the `navigator.onLine` property

`navigator.onLine` doesn't work well in Chromium based browsers. There are [a lot of issues](https://bugs.chromium.org/p/chromium/issues/list?q=navigator.online) around false negatives, which lead to Queries being wrongfully marked as `offline`.

To circumvent this, we now always start with `online: true` and only listen to `online` and `offline` events to update the status.

This should reduce the likelihood of false negatives, however, it might mean false positives for offline apps that load via serviceWorkers, which can work even without an internet connection.

### Removed custom `context` prop in favor of custom `queryClient` instance

In v4, we introduced the possibility to pass a custom `context` to all react-query hooks. This allowed for proper isolation when using MicroFrontends.

However, `context` is a react-only feature. All that `context` does is give us access to the `queryClient`. We could achieve the same isolation by allowing to pass in a custom `queryClient` directly.
This in turn will enable other frameworks to have the same functionality in a framework-agnostic way.

```tsx
import { queryClient } from './my-client'

const { data } = useQuery(
  {
    queryKey: ['users', id],
    queryFn: () => fetch(...),
-   context: customContext // [!code --]
  },
+  queryClient, // [!code ++]
)
```

### Removed `refetchPage` in favor of `maxPages`

In v4, we introduced the possibility to define the pages to refetch for infinite queries with the `refetchPage` function.

However, refetching all pages might lead to UI inconsistencies. Also, this option is available on e.g. `queryClient.refetchQueries`, but it only does something for infinite queries, not "normal" queries.

The v5 includes a new `maxPages` option for infinite queries to limit the number of pages to store in the query data and to refetch. This new feature handles the use cases initially identified for the `refetchPage` page feature without the related issues.

### New `dehydrate` API

The options you can pass to `dehydrate` have been simplified. Queries and Mutations are always dehydrated (according to the default function implementation). To change this behaviour, instead of using the removed boolean options `dehydrateMutations` and `dehydrateQueries` you can implement the function equivalents `shouldDehydrateQuery` or `shouldDehydrateMutation` instead. To get the old behaviour of not hydrating queries/mutations at all, pass in `() => false`.

```tsx
- dehydrateMutations?: boolean // [!code --]
- dehydrateQueries?: boolean // [!code --]
```

### Infinite queries now need a `initialPageParam`

Previously, we've passed `undefined` to the `queryFn` as `pageParam`, and you could assign a default value to the `pageParam` parameter in the `queryFn` function signature. This had the drawback of storing `undefined` in the `queryCache`, which is not serializable.

Instead, you now have to pass an explicit `initialPageParam` to the infinite query options. This will be used as the `pageParam` for the first page:

```tsx
useInfiniteQuery({
   queryKey,
-  queryFn: ({ pageParam = 0 }) => fetchSomething(pageParam), // [!code --]
+  queryFn: ({ pageParam }) => fetchSomething(pageParam), // [!code ++]
+  initialPageParam: 0, // [!code ++]
   getNextPageParam: (lastPage) => lastPage.next,
})
```

### Manual mode for infinite queries has been removed

Previously, we've allowed to overwrite the `pageParams` that would be returned from `getNextPageParam` or `getPreviousPageParam` by passing a `pageParam` value directly to `fetchNextPage` or `fetchPreviousPage`. This feature didn't work at all with refetches and wasn't widely known or used. This also means that `getNextPageParam` is now required for infinite queries.

### Returning `null` from `getNextPageParam` or `getPreviousPageParam` now indicates that there is no further page available

In v4, you needed to explicitly return `undefined` to indicate that there is no further page available. We've widened this check to include `null`.

### No retries on the server

On the server, `retry` now defaults to `0` instead of `3`. For prefetching, we have always defaulted to `0` retries, but since queries that have `suspense` enabled can now execute directly on the server as well (since React18), we have to make sure that we don't retry on the server at all.

### `status: loading` has been changed to `status: pending` and `isLoading` has been changed to `isPending` and `isInitialLoading` has now been renamed to `isLoading`

The `loading` status has been renamed to `pending`, and similarly the derived `isLoading` flag has been renamed to `isPending`.

For mutations as well the `status` has been changed from `loading` to `pending` and the `isLoading` flag has been changed to `isPending`.

Lastly, a new derived `isLoading` flag has been added to the queries that is implemented as `isPending && isFetching`. This means that `isLoading` and `isInitialLoading` have the same thing, but `isInitialLoading` is deprecated now and will be removed in the next major version.

To understand the reasoning behind this change checkout the [v5 roadmap discussion](https://github.com/TanStack/query/discussions/4252).

### `hashQueryKey` has been renamed to `hashKey`

because it also hashes mutation keys and can be used inside the `predicate` functions of `useIsMutating` and `useMutationState`, which gets mutations passed.

[//]: # 'FrameworkSpecificBreakingChanges'

### The minimum required React version is now 18.0

React Query v5 requires React 18.0 or later. This is because we are using the new `useSyncExternalStore` hook, which is only available in React 18.0 and later. Previously, we have been using the shim provided by React.

### The `contextSharing` prop has been removed from QueryClientProvider

You could previously use the `contextSharing` property to share the first (and at least one) instance of the query client context across the window. This ensured that if TanStack Query was used across different bundles or microfrontends then they will all use the same instance of the context, regardless of module scoping.

With the removal of the custom context prop in v5, refer to the section on [Removed custom context prop in favor of custom queryClient instance](#removed-custom-context-prop-in-favor-of-custom-queryclient-instance). If you wish to share the same query client across multiple packages of an application, you can directly pass a shared custom `queryClient` instance.

### No longer using `unstable_batchedUpdates` as the batching function in React and React Native

Since the function `unstable_batchedUpdates` is noop in React 18, it will no longer be automatically set as the batching function in `react-query`.

If your framework supports a custom batching function, you can let TanStack Query know about it by calling `notifyManager.setBatchNotifyFunction`.

For example, this is how the batch function is set in `solid-query`:

```ts
import { notifyManager } from '@tanstack/query-core'
import { batch } from 'solid-js'

notifyManager.setBatchNotifyFunction(batch)
```

### Hydration API changes

To better support concurrent features and transitions we've made some changes to the hydration APIs. The `Hydrate` component has been renamed to `HydrationBoundary` and the `useHydrate` hook has been removed.

The `HydrationBoundary` no longer hydrates mutations, only queries. To hydrate mutations, use the low level `hydrate` API or the `persistQueryClient` plugin.

Finally, as a technical detail, the timing for when queries are hydrated have changed slightly. New queries are still hydrated in the render phase so that SSR works as usual, but any queries that already exist in the cache are now hydrated in an effect instead (as long as their data is fresher than what is in the cache). If you are hydrating just once at the start of your application as is common, this wont affect you, but if you are using Server Components and pass down fresh data for hydration on a page navigation, you might notice a flash of the old data before the page immediately rerenders.

This last change is technically a breaking one, and was made so we don't prematurely update content on the _existing_ page before a page transition has been fully committed. No action is required on your part.

```tsx
- import { Hydrate } from '@tanstack/react-query' // [!code --]
+ import { HydrationBoundary } from '@tanstack/react-query' // [!code ++]


- <Hydrate state={dehydratedState}> // [!code --]
+ <HydrationBoundary state={dehydratedState}> // [!code ++]
  <App />
- </Hydrate> // [!code --]
+ </HydrationBoundary> // [!code ++]
```

[//]: # 'FrameworkSpecificBreakingChanges'

## New Features 🚀

v5 also comes with new features:

### Simplified optimistic updates

We have a new, simplified way to perform optimistic updates by leveraging the returned `variables` from `useMutation`:

```tsx
const queryInfo = useTodos()
const addTodoMutation = useMutation({
  mutationFn: (newTodo: string) => axios.post('/api/data', { text: newTodo }),
  onSettled: () => queryClient.invalidateQueries({ queryKey: ['todos'] }),
})

if (queryInfo.data) {
  return (
    <ul>
      {queryInfo.data.items.map((todo) => (
        <li key={todo.id}>{todo.text}</li>
      ))}
      {addTodoMutation.isPending && (
        <li key={String(addTodoMutation.submittedAt)} style={{ opacity: 0.5 }}>
          {addTodoMutation.variables}
        </li>
      )}
    </ul>
  )
}
```

Here, we are only changing how the UI looks when the mutation is running instead of writing data directly to the cache. This works best if we only have one place where we need to show the optimistic update. For more details, have a look at the [optimistic updates documentation](../optimistic-updates).

### Limited, Infinite Queries with new maxPages option

Infinite queries are great when infinite scroll or pagination are needed.
However, the more pages you fetch, the more memory you consume, and this also slows down the query refetching process as all the pages are sequentially refetched.

Version 5 has a new `maxPages` option for infinite queries, which allows developers to limit the number of pages that are stored in the query data and subsequently refetched.
You can adjust the `maxPages` value according to the UX and refetching performance you want to deliver.

Note that the infinite list must be bi-directional, which requires both `getNextPageParam` and `getPreviousPageParam` to be defined.

### Infinite Queries can prefetch multiple pages

Infinite Queries can be prefetched like regular Queries. Per default, only the first page of the Query will be prefetched and will be stored under the given QueryKey. If you want to prefetch more than one page, you can use the `pages` option. Read the [prefetching guide](../prefetching) for more information.

### New `combine` option for `useQueries`

See the [useQueries docs](../../reference/useQueries#combine) for more details.

### Experimental `fine grained storage persister`

See the [experimental_createPersister docs](../../../react/plugins/createPersister) for more details.

[//]: # 'FrameworkSpecificNewFeatures'

### Typesafe way to create Query Options

See the [TypeScript docs](../../typescript#typing-query-options) for more details.

### new hooks for suspense

With v5, suspense for data fetching finally becomes "stable". We've added dedicated `useSuspenseQuery`, `useSuspenseInfiniteQuery` and `useSuspenseQueries` hooks. With these hooks, `data` will never be potentially `undefined` on type level:

```js
const { data: post } = useSuspenseQuery({
  // ^? const post: Post
  queryKey: ['post', postId],
  queryFn: () => fetchPost(postId),
})
```

The experimental `suspense: boolean` flag on the query hooks has been removed.

You can read more about them in the [suspense docs](../suspense).

[//]: # 'FrameworkSpecificNewFeatures'

---

# mutations


---
id: mutations
title: Mutations
---

Unlike queries, mutations are typically used to create/update/delete data or perform server side-effects. For this purpose, TanStack Query exports a `useMutation` hook.

Here's an example of a mutation that adds a new todo to the server:

[//]: # 'Example'

```tsx
function App() {
  const mutation = useMutation({
    mutationFn: (newTodo) => {
      return axios.post('/todos', newTodo)
    },
  })

  return (
    <div>
      {mutation.isPending ? (
        'Adding todo...'
      ) : (
        <>
          {mutation.isError ? (
            <div>An error occurred: {mutation.error.message}</div>
          ) : null}

          {mutation.isSuccess ? <div>Todo added!</div> : null}

          <button
            onClick={() => {
              mutation.mutate({ id: new Date(), title: 'Do Laundry' })
            }}
          >
            Create Todo
          </button>
        </>
      )}
    </div>
  )
}
```

[//]: # 'Example'

A mutation can only be in one of the following states at any given moment:

- `isIdle` or `status === 'idle'` - The mutation is currently idle or in a fresh/reset state
- `isPending` or `status === 'pending'` - The mutation is currently running
- `isError` or `status === 'error'` - The mutation encountered an error
- `isSuccess` or `status === 'success'` - The mutation was successful and mutation data is available

Beyond those primary states, more information is available depending on the state of the mutation:

- `error` - If the mutation is in an `error` state, the error is available via the `error` property.
- `data` - If the mutation is in a `success` state, the data is available via the `data` property.

In the example above, you also saw that you can pass variables to your mutations function by calling the `mutate` function with a **single variable or object**.

Even with just variables, mutations aren't all that special, but when used with the `onSuccess` option, the [Query Client's `invalidateQueries` method](../../../../reference/QueryClient/#queryclientinvalidatequeries) and the [Query Client's `setQueryData` method](../../../../reference/QueryClient/#queryclientsetquerydata), mutations become a very powerful tool.

[//]: # 'Info1'

> IMPORTANT: The `mutate` function is an asynchronous function, which means you cannot use it directly in an event callback in **React 16 and earlier**. If you need to access the event in `onSubmit` you need to wrap `mutate` in another function. This is due to [React event pooling](https://reactjs.org/docs/legacy-event-pooling.html).

[//]: # 'Info1'
[//]: # 'Example2'

```tsx
// This will not work in React 16 and earlier
const CreateTodo = () => {
  const mutation = useMutation({
    mutationFn: (event) => {
      event.preventDefault()
      return fetch('/api', new FormData(event.target))
    },
  })

  return <form onSubmit={mutation.mutate}>...</form>
}

// This will work
const CreateTodo = () => {
  const mutation = useMutation({
    mutationFn: (formData) => {
      return fetch('/api', formData)
    },
  })
  const onSubmit = (event) => {
    event.preventDefault()
    mutation.mutate(new FormData(event.target))
  }

  return <form onSubmit={onSubmit}>...</form>
}
```

[//]: # 'Example2'

## Resetting Mutation State

It's sometimes the case that you need to clear the `error` or `data` of a mutation request. To do this, you can use the `reset` function to handle this:

[//]: # 'Example3'

```tsx
const CreateTodo = () => {
  const [title, setTitle] = useState('')
  const mutation = useMutation({ mutationFn: createTodo })

  const onCreateTodo = (e) => {
    e.preventDefault()
    mutation.mutate({ title })
  }

  return (
    <form onSubmit={onCreateTodo}>
      {mutation.error && (
        <h5 onClick={() => mutation.reset()}>{mutation.error}</h5>
      )}
      <input
        type="text"
        value={title}
        onChange={(e) => setTitle(e.target.value)}
      />
      <br />
      <button type="submit">Create Todo</button>
    </form>
  )
}
```

[//]: # 'Example3'

## Mutation Side Effects

`useMutation` comes with some helper options that allow quick and easy side-effects at any stage during the mutation lifecycle. These come in handy for both [invalidating and refetching queries after mutations](../invalidations-from-mutations) and even [optimistic updates](../optimistic-updates)

[//]: # 'Example4'

```tsx
useMutation({
  mutationFn: addTodo,
  onMutate: (variables) => {
    // A mutation is about to happen!

    // Optionally return a context containing data to use when for example rolling back
    return { id: 1 }
  },
  onError: (error, variables, context) => {
    // An error happened!
    console.log(`rolling back optimistic update with id ${context.id}`)
  },
  onSuccess: (data, variables, context) => {
    // Boom baby!
  },
  onSettled: (data, error, variables, context) => {
    // Error or success... doesn't matter!
  },
})
```

[//]: # 'Example4'

When returning a promise in any of the callback functions it will first be awaited before the next callback is called:

[//]: # 'Example5'

```tsx
useMutation({
  mutationFn: addTodo,
  onSuccess: async () => {
    console.log("I'm first!")
  },
  onSettled: async () => {
    console.log("I'm second!")
  },
})
```

[//]: # 'Example5'

You might find that you want to **trigger additional callbacks** beyond the ones defined on `useMutation` when calling `mutate`. This can be used to trigger component-specific side effects. To do that, you can provide any of the same callback options to the `mutate` function after your mutation variable. Supported options include: `onSuccess`, `onError` and `onSettled`. Please keep in mind that those additional callbacks won't run if your component unmounts _before_ the mutation finishes.

[//]: # 'Example6'

```tsx
useMutation({
  mutationFn: addTodo,
  onSuccess: (data, variables, context) => {
    // I will fire first
  },
  onError: (error, variables, context) => {
    // I will fire first
  },
  onSettled: (data, error, variables, context) => {
    // I will fire first
  },
})

mutate(todo, {
  onSuccess: (data, variables, context) => {
    // I will fire second!
  },
  onError: (error, variables, context) => {
    // I will fire second!
  },
  onSettled: (data, error, variables, context) => {
    // I will fire second!
  },
})
```

[//]: # 'Example6'

### Consecutive mutations

There is a slight difference in handling `onSuccess`, `onError` and `onSettled` callbacks when it comes to consecutive mutations. When passed to the `mutate` function, they will be fired up only _once_ and only if the component is still mounted. This is due to the fact that mutation observer is removed and resubscribed every time when the `mutate` function is called. On the contrary, `useMutation` handlers execute for each `mutate` call.

> Be aware that most likely, `mutationFn` passed to `useMutation` is asynchronous. In that case, the order in which mutations are fulfilled may differ from the order of `mutate` function calls.

[//]: # 'Example7'

```tsx
useMutation({
  mutationFn: addTodo,
  onSuccess: (data, variables, context) => {
    // Will be called 3 times
  },
})

const todos = ['Todo 1', 'Todo 2', 'Todo 3']
todos.forEach((todo) => {
  mutate(todo, {
    onSuccess: (data, variables, context) => {
      // Will execute only once, for the last mutation (Todo 3),
      // regardless which mutation resolves first
    },
  })
})
```

[//]: # 'Example7'

## Promises

Use `mutateAsync` instead of `mutate` to get a promise which will resolve on success or throw on an error. This can for example be used to compose side effects.

[//]: # 'Example8'

```tsx
const mutation = useMutation({ mutationFn: addTodo })

try {
  const todo = await mutation.mutateAsync(todo)
  console.log(todo)
} catch (error) {
  console.error(error)
} finally {
  console.log('done')
}
```

[//]: # 'Example8'

## Retry

By default, TanStack Query will not retry a mutation on error, but it is possible with the `retry` option:

[//]: # 'Example9'

```tsx
const mutation = useMutation({
  mutationFn: addTodo,
  retry: 3,
})
```

[//]: # 'Example9'

If mutations fail because the device is offline, they will be retried in the same order when the device reconnects.

## Persist mutations

Mutations can be persisted to storage if needed and resumed at a later point. This can be done with the hydration functions:

[//]: # 'Example10'

```tsx
const queryClient = new QueryClient()

// Define the "addTodo" mutation
queryClient.setMutationDefaults(['addTodo'], {
  mutationFn: addTodo,
  onMutate: async (variables) => {
    // Cancel current queries for the todos list
    await queryClient.cancelQueries({ queryKey: ['todos'] })

    // Create optimistic todo
    const optimisticTodo = { id: uuid(), title: variables.title }

    // Add optimistic todo to todos list
    queryClient.setQueryData(['todos'], (old) => [...old, optimisticTodo])

    // Return context with the optimistic todo
    return { optimisticTodo }
  },
  onSuccess: (result, variables, context) => {
    // Replace optimistic todo in the todos list with the result
    queryClient.setQueryData(['todos'], (old) =>
      old.map((todo) =>
        todo.id === context.optimisticTodo.id ? result : todo,
      ),
    )
  },
  onError: (error, variables, context) => {
    // Remove optimistic todo from the todos list
    queryClient.setQueryData(['todos'], (old) =>
      old.filter((todo) => todo.id !== context.optimisticTodo.id),
    )
  },
  retry: 3,
})

// Start mutation in some component:
const mutation = useMutation({ mutationKey: ['addTodo'] })
mutation.mutate({ title: 'title' })

// If the mutation has been paused because the device is for example offline,
// Then the paused mutation can be dehydrated when the application quits:
const state = dehydrate(queryClient)

// The mutation can then be hydrated again when the application is started:
hydrate(queryClient, state)

// Resume the paused mutations:
queryClient.resumePausedMutations()
```

[//]: # 'Example10'

### Persisting Offline mutations

If you persist offline mutations with the [persistQueryClient plugin](../../../react/plugins/persistQueryClient), mutations cannot be resumed when the page is reloaded unless you provide a default mutation function.

This is a technical limitation. When persisting to an external storage, only the state of mutations is persisted, as functions cannot be serialized. After hydration, the component that triggers the mutation might not be mounted, so calling `resumePausedMutations` might yield an error: `No mutationFn found`.

[//]: # 'Example11'

```tsx
const persister = createSyncStoragePersister({
  storage: window.localStorage,
})
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      gcTime: 1000 * 60 * 60 * 24, // 24 hours
    },
  },
})

// we need a default mutation function so that paused mutations can resume after a page reload
queryClient.setMutationDefaults(['todos'], {
  mutationFn: ({ id, data }) => {
    return api.updateTodo(id, data)
  },
})

export default function App() {
  return (
    <PersistQueryClientProvider
      client={queryClient}
      persistOptions={{ persister }}
      onSuccess={() => {
        // resume mutations after initial restore from localStorage was successful
        queryClient.resumePausedMutations()
      }}
    >
      <RestOfTheApp />
    </PersistQueryClientProvider>
  )
}
```

[//]: # 'Example11'

We also have an extensive [offline example](../../examples/offline) that covers both queries and mutations.

## Mutation Scopes

Per default, all mutations run in parallel - even if you invoke `.mutate()` of the same mutation multiple times. Mutations can be given a `scope` with an `id` to avoid that. All mutations with the same `scope.id` will run in serial, which means when they are triggered, they will start in `isPaused: true` state if there is already a mutation for that scope in progress. They will be put into a queue and will automatically resume once their time in the queue has come.

[//]: # 'ExampleScopes'

```tsx
const mutation = useMutation({
  mutationFn: addTodo,
  scope: {
    id: 'todo',
  },
})
```

[//]: # 'ExampleScopes'
[//]: # 'Materials'

## Further reading

For more information about mutations, have a look at [#12: Mastering Mutations in React Query](../../community/tkdodos-blog#12-mastering-mutations-in-react-query) from
the Community Resources.

[//]: # 'Materials'

---

# network-mode


---
id: network-mode
title: Network Mode
---

TanStack Query provides three different network modes to distinguish how [Queries](../queries) and [Mutations](../mutations) should behave if you have no network connection. This mode can be set for each Query / Mutation individually, or globally via the query / mutation defaults.

Since TanStack Query is most often used for data fetching in combination with data fetching libraries, the default network mode is [online](#network-mode-online).

## Network Mode: online

In this mode, Queries and Mutations will not fire unless you have network connection. This is the default mode. If a fetch is initiated for a query, it will always stay in the `state` (`pending`, `error`, `success`) it is in if the fetch cannot be made because there is no network connection. However, a [fetchStatus](../queries#fetchstatus) is exposed additionally. This can be either:

- `fetching`: The `queryFn` is really executing - a request is in-flight.
- `paused`: The query is not executing - it is `paused` until you have connection again
- `idle`: The query is not fetching and not paused

The flags `isFetching` and `isPaused` are derived from this state and exposed for convenience.

> Keep in mind that it might not be enough to check for `pending` state to show a loading spinner. Queries can be in `state: 'pending'`, but `fetchStatus: 'paused'` if they are mounting for the first time, and you have no network connection.

If a query runs because you are online, but you go offline while the fetch is still happening, TanStack Query will also pause the retry mechanism. Paused queries will then continue to run once you re-gain network connection. This is independent of `refetchOnReconnect` (which also defaults to `true` in this mode), because it is not a `refetch`, but rather a `continue`. If the query has been [cancelled](../query-cancellation) in the meantime, it will not continue.

## Network Mode: always

In this mode, TanStack Query will always fetch and ignore the online / offline state. This is likely the mode you want to choose if you use TanStack Query in an environment where you don't need an active network connection for your Queries to work - e.g. if you just read from `AsyncStorage`, or if you just want to return `Promise.resolve(5)` from your `queryFn`.

- Queries will never be `paused` because you have no network connection.
- Retries will also not pause - your Query will go to `error` state if it fails.
- `refetchOnReconnect` defaults to `false` in this mode, because reconnecting to the network is not a good indicator anymore that stale queries should be refetched. You can still turn it on if you want.

## Network Mode: offlineFirst

This mode is the middle ground between the first two options, where TanStack Query will run the `queryFn` once, but then pause retries. This is very handy if you have a serviceWorker that intercepts a request for caching like in an [offline-first PWA](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Offline_Service_workers), or if you use HTTP caching via the [Cache-Control header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Caching#the_cache-control_header).

In those situations, the first fetch might succeed because it comes from an offline storage / cache. However, if there is a cache miss, the network request will go out and fail, in which case this mode behaves like an `online` query - pausing retries.

## Devtools

The [TanStack Query Devtools](../../devtools) will show Queries in a `paused` state if they would be fetching, but there is no network connection. There is also a toggle button to _Mock offline behavior_. Please note that this button will _not_ actually mess with your network connection (you can do that in the browser devtools), but it will set the [OnlineManager](../../../../reference/onlineManager) in an offline state.

## Signature

- `networkMode: 'online' | 'always' | 'offlineFirst'`
  - optional
  - defaults to `'online'`

---

# optimistic-updates


---
id: optimistic-updates
title: Optimistic Updates
---

React Query provides two ways to optimistically update your UI before a mutation has completed. You can either use the `onMutate` option to update your cache directly, or leverage the returned `variables` to update your UI from the `useMutation` result.

## Via the UI

This is the simpler variant, as it doesn't interact with the cache directly.

[//]: # 'ExampleUI1'

```tsx
const addTodoMutation = useMutation({
  mutationFn: (newTodo: string) => axios.post('/api/data', { text: newTodo }),
  // make sure to _return_ the Promise from the query invalidation
  // so that the mutation stays in `pending` state until the refetch is finished
  onSettled: async () => {
    return await queryClient.invalidateQueries({ queryKey: ['todos'] })
  },
})

const { isPending, submittedAt, variables, mutate, isError } = addTodoMutation
```

[//]: # 'ExampleUI1'

you will then have access to `addTodoMutation.variables`, which contain the added todo. In your UI list, where the query is rendered, you can append another item to the list while the mutation `isPending`:

[//]: # 'ExampleUI2'

```tsx
<ul>
  {todoQuery.items.map((todo) => (
    <li key={todo.id}>{todo.text}</li>
  ))}
  {isPending && <li style={{ opacity: 0.5 }}>{variables}</li>}
</ul>
```

[//]: # 'ExampleUI2'

We're rendering a temporary item with a different `opacity` as long as the mutation is pending. Once it completes, the item will automatically no longer be rendered. Given that the refetch succeeded, we should see the item as a "normal item" in our list.

If the mutation errors, the item will also disappear. But we could continue to show it, if we want, by checking for the `isError` state of the mutation. `variables` are _not_ cleared when the mutation errors, so we can still access them, maybe even show a retry button:

[//]: # 'ExampleUI3'

```tsx
{
  isError && (
    <li style={{ color: 'red' }}>
      {variables}
      <button onClick={() => mutate(variables)}>Retry</button>
    </li>
  )
}
```

[//]: # 'ExampleUI3'

### If the mutation and the query don't live in the same component

This approach works very well if the mutation and the query live in the same component, However, you also get access to all mutations in other components via the dedicated `useMutationState` hook. It is best combined with a `mutationKey`:

[//]: # 'ExampleUI4'

```tsx
// somewhere in your app
const { mutate } = useMutation({
  mutationFn: (newTodo: string) => axios.post('/api/data', { text: newTodo }),
  onSettled: () => queryClient.invalidateQueries({ queryKey: ['todos'] }),
  mutationKey: ['addTodo'],
})

// access variables somewhere else
const variables = useMutationState<string>({
  filters: { mutationKey: ['addTodo'], status: 'pending' },
  select: (mutation) => mutation.state.variables,
})
```

[//]: # 'ExampleUI4'

`variables` will be an `Array`, because there might be multiple mutations running at the same time. If we need a unique key for the items, we can also select `mutation.state.submittedAt`. This will even make displaying concurrent optimistic updates a breeze.

## Via the cache

When you optimistically update your state before performing a mutation, there is a chance that the mutation will fail. In most of these failure cases, you can just trigger a refetch for your optimistic queries to revert them to their true server state. In some circumstances though, refetching may not work correctly and the mutation error could represent some type of server issue that won't make it possible to refetch. In this event, you can instead choose to roll back your update.

To do this, `useMutation`'s `onMutate` handler option allows you to return a value that will later be passed to both `onError` and `onSettled` handlers as the last argument. In most cases, it is most useful to pass a rollback function.

### Updating a list of todos when adding a new todo

[//]: # 'Example'

```tsx
const queryClient = useQueryClient()

useMutation({
  mutationFn: updateTodo,
  // When mutate is called:
  onMutate: async (newTodo) => {
    // Cancel any outgoing refetches
    // (so they don't overwrite our optimistic update)
    await queryClient.cancelQueries({ queryKey: ['todos'] })

    // Snapshot the previous value
    const previousTodos = queryClient.getQueryData(['todos'])

    // Optimistically update to the new value
    queryClient.setQueryData(['todos'], (old) => [...old, newTodo])

    // Return a context object with the snapshotted value
    return { previousTodos }
  },
  // If the mutation fails,
  // use the context returned from onMutate to roll back
  onError: (err, newTodo, context) => {
    queryClient.setQueryData(['todos'], context.previousTodos)
  },
  // Always refetch after error or success:
  onSettled: () => {
    queryClient.invalidateQueries({ queryKey: ['todos'] })
  },
})
```

[//]: # 'Example'

### Updating a single todo

[//]: # 'Example2'

```tsx
useMutation({
  mutationFn: updateTodo,
  // When mutate is called:
  onMutate: async (newTodo) => {
    // Cancel any outgoing refetches
    // (so they don't overwrite our optimistic update)
    await queryClient.cancelQueries({ queryKey: ['todos', newTodo.id] })

    // Snapshot the previous value
    const previousTodo = queryClient.getQueryData(['todos', newTodo.id])

    // Optimistically update to the new value
    queryClient.setQueryData(['todos', newTodo.id], newTodo)

    // Return a context with the previous and new todo
    return { previousTodo, newTodo }
  },
  // If the mutation fails, use the context we returned above
  onError: (err, newTodo, context) => {
    queryClient.setQueryData(
      ['todos', context.newTodo.id],
      context.previousTodo,
    )
  },
  // Always refetch after error or success:
  onSettled: (newTodo) => {
    queryClient.invalidateQueries({ queryKey: ['todos', newTodo.id] })
  },
})
```

[//]: # 'Example2'

You can also use the `onSettled` function in place of the separate `onError` and `onSuccess` handlers if you wish:

[//]: # 'Example3'

```tsx
useMutation({
  mutationFn: updateTodo,
  // ...
  onSettled: (newTodo, error, variables, context) => {
    if (error) {
      // do something
    }
  },
})
```

[//]: # 'Example3'

## When to use what

If you only have one place where the optimistic result should be shown, using `variables` and updating the UI directly is the approach that requires less code and is generally easier to reason about. For example, you don't need to handle rollbacks at all.

However, if you have multiple places on the screen that would require to know about the update, manipulating the cache directly will take care of this for you automatically.

---

# paginated-queries


---
id: paginated-queries
title: Paginated / Lagged Queries
---

Rendering paginated data is a very common UI pattern and in TanStack Query, it "just works" by including the page information in the query key:

[//]: # 'Example'

```tsx
const result = useQuery({
  queryKey: ['projects', page],
  queryFn: fetchProjects,
})
```

[//]: # 'Example'

However, if you run this simple example, you might notice something strange:

**The UI jumps in and out of the `success` and `pending` states because each new page is treated like a brand new query.**

This experience is not optimal and unfortunately is how many tools today insist on working. But not TanStack Query! As you may have guessed, TanStack Query comes with an awesome feature called `placeholderData` that allows us to get around this.

## Better Paginated Queries with `placeholderData`

Consider the following example where we would ideally want to increment a pageIndex (or cursor) for a query. If we were to use `useQuery`, **it would still technically work fine**, but the UI would jump in and out of the `success` and `pending` states as different queries are created and destroyed for each page or cursor. By setting `placeholderData` to `(previousData) => previousData` or `keepPreviousData` function exported from TanStack Query, we get a few new things:

- **The data from the last successful fetch is available while new data is being requested, even though the query key has changed**.
- When the new data arrives, the previous `data` is seamlessly swapped to show the new data.
- `isPlaceholderData` is made available to know what data the query is currently providing you

[//]: # 'Example2'

```tsx
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import React from 'react'

function Todos() {
  const [page, setPage] = React.useState(0)

  const fetchProjects = (page = 0) =>
    fetch('/api/projects?page=' + page).then((res) => res.json())

  const { isPending, isError, error, data, isFetching, isPlaceholderData } =
    useQuery({
      queryKey: ['projects', page],
      queryFn: () => fetchProjects(page),
      placeholderData: keepPreviousData,
    })

  return (
    <div>
      {isPending ? (
        <div>Loading...</div>
      ) : isError ? (
        <div>Error: {error.message}</div>
      ) : (
        <div>
          {data.projects.map((project) => (
            <p key={project.id}>{project.name}</p>
          ))}
        </div>
      )}
      <span>Current Page: {page + 1}</span>
      <button
        onClick={() => setPage((old) => Math.max(old - 1, 0))}
        disabled={page === 0}
      >
        Previous Page
      </button>
      <button
        onClick={() => {
          if (!isPlaceholderData && data.hasMore) {
            setPage((old) => old + 1)
          }
        }}
        // Disable the Next Page button until we know a next page is available
        disabled={isPlaceholderData || !data?.hasMore}
      >
        Next Page
      </button>
      {isFetching ? <span> Loading...</span> : null}
    </div>
  )
}
```

[//]: # 'Example2'

## Lagging Infinite Query results with `placeholderData`

While not as common, the `placeholderData` option also works flawlessly with the `useInfiniteQuery` hook, so you can seamlessly allow your users to continue to see cached data while infinite query keys change over time.

---

# parallel-queries


---
id: parallel-queries
title: Parallel Queries
---

"Parallel" queries are queries that are executed in parallel, or at the same time so as to maximize fetching concurrency.

## Manual Parallel Queries

When the number of parallel queries does not change, there is **no extra effort** to use parallel queries. Just use any number of TanStack Query's `useQuery` and `useInfiniteQuery` hooks side-by-side!

[//]: # 'Example'

```tsx
function App () {
  // The following queries will execute in parallel
  const usersQuery = useQuery({ queryKey: ['users'], queryFn: fetchUsers })
  const teamsQuery = useQuery({ queryKey: ['teams'], queryFn: fetchTeams })
  const projectsQuery = useQuery({ queryKey: ['projects'], queryFn: fetchProjects })
  ...
}
```

[//]: # 'Example'
[//]: # 'Info'

> When using React Query in suspense mode, this pattern of parallelism does not work, since the first query would throw a promise internally and would suspend the component before the other queries run. To get around this, you'll either need to use the `useSuspenseQueries` hook (which is suggested) or orchestrate your own parallelism with separate components for each `useSuspenseQuery` instance.

[//]: # 'Info'

## Dynamic Parallel Queries with `useQueries`

[//]: # 'DynamicParallelIntro'

If the number of queries you need to execute is changing from render to render, you cannot use manual querying since that would violate the rules of hooks. Instead, TanStack Query provides a `useQueries` hook, which you can use to dynamically execute as many queries in parallel as you'd like.

[//]: # 'DynamicParallelIntro'

`useQueries` accepts an **options object** with a **queries key** whose value is an **array of query objects**. It returns an **array of query results**:

[//]: # 'Example2'

```tsx
function App({ users }) {
  const userQueries = useQueries({
    queries: users.map((user) => {
      return {
        queryKey: ['user', user.id],
        queryFn: () => fetchUserById(user.id),
      }
    }),
  })
}
```

[//]: # 'Example2'

---

# placeholder-query-data


---
id: placeholder-query-data
title: Placeholder Query Data
---

## What is placeholder data?

Placeholder data allows a query to behave as if it already has data, similar to the `initialData` option, but **the data is not persisted to the cache**. This comes in handy for situations where you have enough partial (or fake) data to render the query successfully while the actual data is fetched in the background.

> Example: An individual blog post query could pull "preview" data from a parent list of blog posts that only include title and a small snippet of the post body. You would not want to persist this partial data to the query result of the individual query, but it is useful for showing the content layout as quickly as possible while the actual query finishes to fetch the entire object.

There are a few ways to supply placeholder data for a query to the cache before you need it:

- Declaratively:
  - Provide `placeholderData` to a query to prepopulate its cache if empty
- Imperatively:
  - [Prefetch or fetch the data using `queryClient` and the `placeholderData` option](../../../react/guides/prefetching)

When we use `placeholderData`, our Query will not be in a `pending` state - it will start out as being in `success` state, because we have `data` to display - even if that data is just "placeholder" data. To distinguish it from "real" data, we will also have the `isPlaceholderData` flag set to `true` on the Query result.

## Placeholder Data as a Value

[//]: # 'ExampleValue'

```tsx
function Todos() {
  const result = useQuery({
    queryKey: ['todos'],
    queryFn: () => fetch('/todos'),
    placeholderData: placeholderTodos,
  })
}
```

[//]: # 'ExampleValue'
[//]: # 'Memoization'

### Placeholder Data Memoization

If the process for accessing a query's placeholder data is intensive or just not something you want to perform on every render, you can memoize the value:

```tsx
function Todos() {
  const placeholderData = useMemo(() => generateFakeTodos(), [])
  const result = useQuery({
    queryKey: ['todos'],
    queryFn: () => fetch('/todos'),
    placeholderData,
  })
}
```

[//]: # 'Memoization'

## Placeholder Data as a Function

`placeholderData` can also be a function, where you can get access to the data and Query meta information of a "previous" successful Query. This is useful for situations where you want to use the data from one query as the placeholder data for another query. When the QueryKey changes, e.g. from `['todos', 1]` to `['todos', 2]`, we can keep displaying "old" data instead of having to show a loading spinner while data is _transitioning_ from one Query to the next. For more information, see [Paginated Queries](../paginated-queries).

[//]: # 'ExampleFunction'

```tsx
const result = useQuery({
  queryKey: ['todos', id],
  queryFn: () => fetch(`/todos/${id}`),
  placeholderData: (previousData, previousQuery) => previousData,
})
```

[//]: # 'ExampleFunction'

### Placeholder Data from Cache

In some circumstances, you may be able to provide the placeholder data for a query from the cached result of another. A good example of this would be searching the cached data from a blog post list query for a preview version of the post, then using that as the placeholder data for your individual post query:

[//]: # 'ExampleCache'

```tsx
function Todo({ blogPostId }) {
  const queryClient = useQueryClient()
  const result = useQuery({
    queryKey: ['blogPost', blogPostId],
    queryFn: () => fetch(`/blogPosts/${blogPostId}`),
    placeholderData: () => {
      // Use the smaller/preview version of the blogPost from the 'blogPosts'
      // query as the placeholder data for this blogPost query
      return queryClient
        .getQueryData(['blogPosts'])
        ?.find((d) => d.id === blogPostId)
    },
  })
}
```

[//]: # 'ExampleCache'
[//]: # 'Materials'

## Further reading

For a comparison between `Placeholder Data` and `Initial Data`, have a look at the [Community Resources](../../community/tkdodos-blog#9-placeholder-and-initial-data-in-react-query).

[//]: # 'Materials'

---

# prefetching


---
id: prefetching
title: Prefetching & Router Integration
---

When you know or suspect that a certain piece of data will be needed, you can use prefetching to populate the cache with that data ahead of time, leading to a faster experience.

There are a few different prefetching patterns:

1. In event handlers
2. In components
3. Via router integration
4. During Server Rendering (another form of router integration)

In this guide, we'll take a look at the first three, while the fourth will be covered in depth in the [Server Rendering & Hydration guide](../ssr) and the [Advanced Server Rendering guide](../advanced-ssr).

One specific use of prefetching is to avoid Request Waterfalls, for an in-depth background and explanation of those, see the [Performance & Request Waterfalls guide](../request-waterfalls).

## prefetchQuery & prefetchInfiniteQuery

Before jumping into the different specific prefetch patterns, let's look at the `prefetchQuery` and `prefetchInfiniteQuery` functions. First a few basics:

- Out of the box, these functions use the default `staleTime` configured for the `queryClient` to determine whether existing data in the cache is fresh or needs to be fetched again
- You can also pass a specific `staleTime` like this: `prefetchQuery({ queryKey: ['todos'], queryFn: fn, staleTime: 5000 })`
  - This `staleTime` is only used for the prefetch, you still need to set it for any `useQuery` call as well
  - If you want to ignore `staleTime` and instead always return data if it's available in the cache, you can use the `ensureQueryData` function.
  - Tip: If you are prefetching on the server, set a default `staleTime` higher than `0` for that `queryClient` to avoid having to pass in a specific `staleTime` to each prefetch call
- If no instances of `useQuery` appear for a prefetched query, it will be deleted and garbage collected after the time specified in `gcTime`
- These functions returns `Promise<void>` and thus never return query data. If that's something you need, use `fetchQuery`/`fetchInfiniteQuery` instead.
- The prefetch functions never throws errors because they usually try to fetch again in a `useQuery` which is a nice graceful fallback. If you need to catch errors, use `fetchQuery`/`fetchInfiniteQuery` instead.

This is how you use `prefetchQuery`:

[//]: # 'ExamplePrefetchQuery'

```tsx
const prefetchTodos = async () => {
  // The results of this query will be cached like a normal query
  await queryClient.prefetchQuery({
    queryKey: ['todos'],
    queryFn: fetchTodos,
  })
}
```

[//]: # 'ExamplePrefetchQuery'

Infinite Queries can be prefetched like regular Queries. Per default, only the first page of the Query will be prefetched and will be stored under the given QueryKey. If you want to prefetch more than one page, you can use the `pages` option, in which case you also have to provide a `getNextPageParam` function:

[//]: # 'ExamplePrefetchInfiniteQuery'

```tsx
const prefetchProjects = async () => {
  // The results of this query will be cached like a normal query
  await queryClient.prefetchInfiniteQuery({
    queryKey: ['projects'],
    queryFn: fetchProjects,
    initialPageParam: 0,
    getNextPageParam: (lastPage, pages) => lastPage.nextCursor,
    pages: 3, // prefetch the first 3 pages
  })
}
```

[//]: # 'ExamplePrefetchInfiniteQuery'

Next, let's look at how you can use these and other ways to prefetch in different situations.

## Prefetch in event handlers

A straightforward form of prefetching is doing it when the user interacts with something. In this example we'll use `queryClient.prefetchQuery` to start a prefetch on `onMouseEnter` or `onFocus`.

[//]: # 'ExampleEventHandler'

```tsx
function ShowDetailsButton() {
  const queryClient = useQueryClient()

  const prefetch = () => {
    queryClient.prefetchQuery({
      queryKey: ['details'],
      queryFn: getDetailsData,
      // Prefetch only fires when data is older than the staleTime,
      // so in a case like this you definitely want to set one
      staleTime: 60000,
    })
  }

  return (
    <button onMouseEnter={prefetch} onFocus={prefetch} onClick={...}>
      Show Details
    </button>
  )
}
```

[//]: # 'ExampleEventHandler'

## Prefetch in components

Prefetching during the component lifecycle is useful when we know some child or descendant will need a particular piece of data, but we can't render that until some other query has finished loading. Let's borrow an example from the Request Waterfall guide to explain:

[//]: # 'ExampleComponent'

```tsx
function Article({ id }) {
  const { data: articleData, isPending } = useQuery({
    queryKey: ['article', id],
    queryFn: getArticleById,
  })

  if (isPending) {
    return 'Loading article...'
  }

  return (
    <>
      <ArticleHeader articleData={articleData} />
      <ArticleBody articleData={articleData} />
      <Comments id={id} />
    </>
  )
}

function Comments({ id }) {
  const { data, isPending } = useQuery({
    queryKey: ['article-comments', id],
    queryFn: getArticleCommentsById,
  })

  ...
}
```

[//]: # 'ExampleComponent'

This results in a request waterfall looking like this:

```
1. |> getArticleById()
2.   |> getArticleCommentsById()
```

As mentioned in that guide, one way to flatten this waterfall and improve performance is to hoist the `getArticleCommentsById` query to the parent and pass down the result as a prop, but what if this is not feasible or desirable, for example when the components are unrelated and have multiple levels between them?

In that case, we can instead prefetch the query in the parent. The simplest way to do this is to use a query but ignore the result:

[//]: # 'ExampleParentComponent'

```tsx
function Article({ id }) {
  const { data: articleData, isPending } = useQuery({
    queryKey: ['article', id],
    queryFn: getArticleById,
  })

  // Prefetch
  useQuery({
    queryKey: ['article-comments', id],
    queryFn: getArticleCommentsById,
    // Optional optimization to avoid rerenders when this query changes:
    notifyOnChangeProps: [],
  })

  if (isPending) {
    return 'Loading article...'
  }

  return (
    <>
      <ArticleHeader articleData={articleData} />
      <ArticleBody articleData={articleData} />
      <Comments id={id} />
    </>
  )
}

function Comments({ id }) {
  const { data, isPending } = useQuery({
    queryKey: ['article-comments', id],
    queryFn: getArticleCommentsById,
  })

  ...
}
```

[//]: # 'ExampleParentComponent'

This starts fetching `'article-comments'` immediately and flattens the waterfall:

```
1. |> getArticleById()
1. |> getArticleCommentsById()
```

[//]: # 'Suspense'

If you want to prefetch together with Suspense, you will have to do things a bit differently. You can't use `useSuspenseQueries` to prefetch, since the prefetch would block the component from rendering. You also can not use `useQuery` for the prefetch, because that wouldn't start the prefetch until after suspenseful query had resolved. For this scenario, you can use the [`usePrefetchQuery`](../../reference/usePrefetchQuery) or the [`usePrefetchInfiniteQuery`](../../reference/usePrefetchInfiniteQuery) hooks available in the library.

You can now use `useSuspenseQuery` in the component that actually needs the data. You _might_ want to wrap this later component in its own `<Suspense>` boundary so the "secondary" query we are prefetching does not block rendering of the "primary" data.

```tsx
function ArticleLayout({ id }) {
  usePrefetchQuery({
    queryKey: ['article-comments', id],
    queryFn: getArticleCommentsById,
  })

  return (
    <Suspense fallback="Loading article">
      <Article id={id} />
    </Suspense>
  )
}

function Article({ id }) {
  const { data: articleData, isPending } = useSuspenseQuery({
    queryKey: ['article', id],
    queryFn: getArticleById,
  })

  ...
}
```

Another way is to prefetch inside of the query function. This makes sense if you know that every time an article is fetched it's very likely comments will also be needed. For this, we'll use `queryClient.prefetchQuery`:

```tsx
const queryClient = useQueryClient()
const { data: articleData, isPending } = useQuery({
  queryKey: ['article', id],
  queryFn: (...args) => {
    queryClient.prefetchQuery({
      queryKey: ['article-comments', id],
      queryFn: getArticleCommentsById,
    })

    return getArticleById(...args)
  },
})
```

Prefetching in an effect also works, but note that if you are using `useSuspenseQuery` in the same component, this effect wont run until _after_ the query finishes which might not be what you want.

```tsx
const queryClient = useQueryClient()

useEffect(() => {
  queryClient.prefetchQuery({
    queryKey: ['article-comments', id],
    queryFn: getArticleCommentsById,
  })
}, [queryClient, id])
```

To recap, if you want to prefetch a query during the component lifecycle, there are a few different ways to do it, pick the one that suits your situation best:

- Prefetch before a suspense boundary using `usePrefetchQuery` or `usePrefetchInfiniteQuery` hooks
- Use `useQuery` or `useSuspenseQueries` and ignore the result
- Prefetch inside the query function
- Prefetch in an effect

Let's look at a slightly more advanced case next.

[//]: # 'Suspense'

### Dependent Queries & Code Splitting

Sometimes we want to prefetch conditionally, based on the result of another fetch. Consider this example borrowed from the [Performance & Request Waterfalls guide](../request-waterfalls):

[//]: # 'ExampleConditionally1'

```tsx
// This lazy loads the GraphFeedItem component, meaning
// it wont start loading until something renders it
const GraphFeedItem = React.lazy(() => import('./GraphFeedItem'))

function Feed() {
  const { data, isPending } = useQuery({
    queryKey: ['feed'],
    queryFn: getFeed,
  })

  if (isPending) {
    return 'Loading feed...'
  }

  return (
    <>
      {data.map((feedItem) => {
        if (feedItem.type === 'GRAPH') {
          return <GraphFeedItem key={feedItem.id} feedItem={feedItem} />
        }

        return <StandardFeedItem key={feedItem.id} feedItem={feedItem} />
      })}
    </>
  )
}

// GraphFeedItem.tsx
function GraphFeedItem({ feedItem }) {
  const { data, isPending } = useQuery({
    queryKey: ['graph', feedItem.id],
    queryFn: getGraphDataById,
  })

  ...
}
```

[//]: # 'ExampleConditionally1'

As noted over in that guide, this example leads to the following double request waterfall:

```
1. |> getFeed()
2.   |> JS for <GraphFeedItem>
3.     |> getGraphDataById()
```

If we can not restructure our API so `getFeed()` also returns the `getGraphDataById()` data when necessary, there is no way to get rid of the `getFeed->getGraphDataById` waterfall, but by leveraging conditional prefetching, we can at least load the code and data in parallel. Just like described above, there are multiple ways to do this, but for this example, we'll do it in the query function:

[//]: # 'ExampleConditionally2'

```tsx
function Feed() {
  const queryClient = useQueryClient()
  const { data, isPending } = useQuery({
    queryKey: ['feed'],
    queryFn: async (...args) => {
      const feed = await getFeed(...args)

      for (const feedItem of feed) {
        if (feedItem.type === 'GRAPH') {
          queryClient.prefetchQuery({
            queryKey: ['graph', feedItem.id],
            queryFn: getGraphDataById,
          })
        }
      }

      return feed
    }
  })

  ...
}
```

[//]: # 'ExampleConditionally2'

This would load the code and data in parallel:

```
1. |> getFeed()
2.   |> JS for <GraphFeedItem>
2.   |> getGraphDataById()
```

There is a tradeoff however, in that the code for `getGraphDataById` is now included in the parent bundle instead of in `JS for <GraphFeedItem>` so you'll need to determine what's the best performance tradeoff on a case by case basis. If `GraphFeedItem` are likely, it's probably worth to include the code in the parent. If they are exceedingly rare, it's probably not.

[//]: # 'Router'

## Router Integration

Because data fetching in the component tree itself can easily lead to request waterfalls and the different fixes for that can be cumbersome as they accumulate throughout the application, an attractive way to do prefetching is integrating it at the router level.

In this approach, you explicitly declare for each _route_ what data is going to be needed for that component tree, ahead of time. Because Server Rendering has traditionally needed all data to be loaded before rendering starts, this has been the dominating approach for SSR'd apps for a long time. This is still a common approach and you can read more about it in the [Server Rendering & Hydration guide](../ssr).

For now, let's focus on the client side case and look at an example of how you can make this work with [Tanstack Router](https://tanstack.com/router). These examples leave out a lot of setup and boilerplate to stay concise, you can check out a [full React Query example](https://tanstack.com/router/v1/docs/framework/react/examples/basic-react-query-file-based) over in the [Tanstack Router docs](https://tanstack.com/router/v1/docs).

When integrating at the router level, you can choose to either _block_ rendering of that route until all data is present, or you can start a prefetch but not await the result. That way, you can start rendering the route as soon as possible. You can also mix these two approaches and await some critical data, but start rendering before all the secondary data has finished loading. In this example, we'll configure an `/article` route to not render until the article data has finished loading, as well as start prefetching comments as soon as possible, but not block rendering the route if comments haven't finished loading yet.

```tsx
const queryClient = new QueryClient()
const routerContext = new RouterContext()
const rootRoute = routerContext.createRootRoute({
  component: () => { ... }
})

const articleRoute = new Route({
  getParentRoute: () => rootRoute,
  path: 'article',
  beforeLoad: () => {
    return {
      articleQueryOptions: { queryKey: ['article'], queryFn: fetchArticle },
      commentsQueryOptions: { queryKey: ['comments'], queryFn: fetchComments },
    }
  },
  loader: async ({
    context: { queryClient },
    routeContext: { articleQueryOptions, commentsQueryOptions },
  }) => {
    // Fetch comments asap, but don't block
    queryClient.prefetchQuery(commentsQueryOptions)

    // Don't render the route at all until article has been fetched
    await queryClient.prefetchQuery(articleQueryOptions)
  },
  component: ({ useRouteContext }) => {
    const { articleQueryOptions, commentsQueryOptions } = useRouteContext()
    const articleQuery = useQuery(articleQueryOptions)
    const commentsQuery = useQuery(commentsQueryOptions)

    return (
      ...
    )
  },
  errorComponent: () => 'Oh crap!',
})
```

Integration with other routers is also possible, see the [React Router example](../../examples/react-router) for another demonstration.

[//]: # 'Router'

## Manually Priming a Query

If you already have the data for your query synchronously available, you don't need to prefetch it. You can just use the [Query Client's `setQueryData` method](../../../../reference/QueryClient/#queryclientsetquerydata) to directly add or update a query's cached result by key.

[//]: # 'ExampleManualPriming'

```tsx
queryClient.setQueryData(['todos'], todos)
```

[//]: # 'ExampleManualPriming'
[//]: # 'Materials'

## Further reading

For a deep-dive on how to get data into your Query Cache before you fetch, have a look at [#17: Seeding the Query Cache](../../community/tkdodos-blog#17-seeding-the-query-cache) from the Community Resources.

Integrating with Server Side routers and frameworks is very similar to what we just saw, with the addition that the data has to passed from the server to the client to be hydrated into the cache there. To learn how, continue on to the [Server Rendering & Hydration guide](../ssr).

[//]: # 'Materials'

---

# queries


---
id: queries
title: Queries
---

## Query Basics

A query is a declarative dependency on an asynchronous source of data that is tied to a **unique key**. A query can be used with any Promise based method (including GET and POST methods) to fetch data from a server. If your method modifies data on the server, we recommend using [Mutations](../mutations) instead.

To subscribe to a query in your components or custom hooks, call the `useQuery` hook with at least:

- A **unique key for the query**
- A function that returns a promise that:
  - Resolves the data, or
  - Throws an error

[//]: # 'Example'

```tsx
import { useQuery } from '@tanstack/react-query'

function App() {
  const info = useQuery({ queryKey: ['todos'], queryFn: fetchTodoList })
}
```

[//]: # 'Example'

The **unique key** you provide is used internally for refetching, caching, and sharing your queries throughout your application.

The query result returned by `useQuery` contains all of the information about the query that you'll need for templating and any other usage of the data:

[//]: # 'Example2'

```tsx
const result = useQuery({ queryKey: ['todos'], queryFn: fetchTodoList })
```

[//]: # 'Example2'

The `result` object contains a few very important states you'll need to be aware of to be productive. A query can only be in one of the following states at any given moment:

- `isPending` or `status === 'pending'` - The query has no data yet
- `isError` or `status === 'error'` - The query encountered an error
- `isSuccess` or `status === 'success'` - The query was successful and data is available

Beyond those primary states, more information is available depending on the state of the query:

- `error` - If the query is in an `isError` state, the error is available via the `error` property.
- `data` - If the query is in an `isSuccess` state, the data is available via the `data` property.
- `isFetching` - In any state, if the query is fetching at any time (including background refetching) `isFetching` will be `true`.

For **most** queries, it's usually sufficient to check for the `isPending` state, then the `isError` state, then finally, assume that the data is available and render the successful state:

[//]: # 'Example3'

```tsx
function Todos() {
  const { isPending, isError, data, error } = useQuery({
    queryKey: ['todos'],
    queryFn: fetchTodoList,
  })

  if (isPending) {
    return <span>Loading...</span>
  }

  if (isError) {
    return <span>Error: {error.message}</span>
  }

  // We can assume by this point that `isSuccess === true`
  return (
    <ul>
      {data.map((todo) => (
        <li key={todo.id}>{todo.title}</li>
      ))}
    </ul>
  )
}
```

[//]: # 'Example3'

If booleans aren't your thing, you can always use the `status` state as well:

[//]: # 'Example4'

```tsx
function Todos() {
  const { status, data, error } = useQuery({
    queryKey: ['todos'],
    queryFn: fetchTodoList,
  })

  if (status === 'pending') {
    return <span>Loading...</span>
  }

  if (status === 'error') {
    return <span>Error: {error.message}</span>
  }

  // also status === 'success', but "else" logic works, too
  return (
    <ul>
      {data.map((todo) => (
        <li key={todo.id}>{todo.title}</li>
      ))}
    </ul>
  )
}
```

[//]: # 'Example4'

TypeScript will also narrow the type of `data` correctly if you've checked for `pending` and `error` before accessing it.

### FetchStatus

In addition to the `status` field, you will also get an additional `fetchStatus` property with the following options:

- `fetchStatus === 'fetching'` - The query is currently fetching.
- `fetchStatus === 'paused'` - The query wanted to fetch, but it is paused. Read more about this in the [Network Mode](../network-mode) guide.
- `fetchStatus === 'idle'` - The query is not doing anything at the moment.

### Why two different states?

Background refetches and stale-while-revalidate logic make all combinations for `status` and `fetchStatus` possible. For example:

- a query in `success` status will usually be in `idle` fetchStatus, but it could also be in `fetching` if a background refetch is happening.
- a query that mounts and has no data will usually be in `pending` status and `fetching` fetchStatus, but it could also be `paused` if there is no network connection.

So keep in mind that a query can be in `pending` state without actually fetching data. As a rule of thumb:

- The `status` gives information about the `data`: Do we have any or not?
- The `fetchStatus` gives information about the `queryFn`: Is it running or not?

[//]: # 'Materials'

## Further Reading

For an alternative way of performing status checks, have a look at the [Community Resources](../../community/tkdodos-blog#4-status-checks-in-react-query).

[//]: # 'Materials'

---

# query-cancellation


---
id: query-cancellation
title: Query Cancellation
---

TanStack Query provides each query function with an [`AbortSignal` instance](https://developer.mozilla.org/docs/Web/API/AbortSignal). When a query becomes out-of-date or inactive, this `signal` will become aborted. This means that all queries are cancellable, and you can respond to the cancellation inside your query function if desired. The best part about this is that it allows you to continue to use normal async/await syntax while getting all the benefits of automatic cancellation.

The `AbortController` API is available in [most runtime environments](https://developer.mozilla.org/docs/Web/API/AbortController#browser_compatibility), but if your runtime environment does not support it, you will need to provide a polyfill. There are [several available](https://www.npmjs.com/search?q=abortcontroller%20polyfill).

## Default behavior

By default, queries that unmount or become unused before their promises are resolved are _not_ cancelled. This means that after the promise has resolved, the resulting data will be available in the cache. This is helpful if you've started receiving a query, but then unmount the component before it finishes. If you mount the component again and the query has not been garbage collected yet, data will be available.

However, if you consume the `AbortSignal`, the Promise will be cancelled (e.g. aborting the fetch) and therefore, also the Query must be cancelled. Cancelling the query will result in its state being _reverted_ to its previous state.

## Using `fetch`

[//]: # 'Example'

```tsx
const query = useQuery({
  queryKey: ['todos'],
  queryFn: async ({ signal }) => {
    const todosResponse = await fetch('/todos', {
      // Pass the signal to one fetch
      signal,
    })
    const todos = await todosResponse.json()

    const todoDetails = todos.map(async ({ details }) => {
      const response = await fetch(details, {
        // Or pass it to several
        signal,
      })
      return response.json()
    })

    return Promise.all(todoDetails)
  },
})
```

[//]: # 'Example'

## Using `axios` [v0.22.0+](https://github.com/axios/axios/releases/tag/v0.22.0)

[//]: # 'Example2'

```tsx
import axios from 'axios'

const query = useQuery({
  queryKey: ['todos'],
  queryFn: ({ signal }) =>
    axios.get('/todos', {
      // Pass the signal to `axios`
      signal,
    }),
})
```

[//]: # 'Example2'

### Using `axios` with version lower than v0.22.0

[//]: # 'Example3'

```tsx
import axios from 'axios'

const query = useQuery({
  queryKey: ['todos'],
  queryFn: ({ signal }) => {
    // Create a new CancelToken source for this request
    const CancelToken = axios.CancelToken
    const source = CancelToken.source()

    const promise = axios.get('/todos', {
      // Pass the source token to your request
      cancelToken: source.token,
    })

    // Cancel the request if TanStack Query signals to abort
    signal?.addEventListener('abort', () => {
      source.cancel('Query was cancelled by TanStack Query')
    })

    return promise
  },
})
```

[//]: # 'Example3'

## Using `XMLHttpRequest`

[//]: # 'Example4'

```tsx
const query = useQuery({
  queryKey: ['todos'],
  queryFn: ({ signal }) => {
    return new Promise((resolve, reject) => {
      var oReq = new XMLHttpRequest()
      oReq.addEventListener('load', () => {
        resolve(JSON.parse(oReq.responseText))
      })
      signal?.addEventListener('abort', () => {
        oReq.abort()
        reject()
      })
      oReq.open('GET', '/todos')
      oReq.send()
    })
  },
})
```

[//]: # 'Example4'

## Using `graphql-request`

An `AbortSignal` can be set in the client `request` method.

[//]: # 'Example5'

```tsx
const client = new GraphQLClient(endpoint)

const query = useQuery({
  queryKey: ['todos'],
  queryFn: ({ signal }) => {
    client.request({ document: query, signal })
  },
})
```

[//]: # 'Example5'

## Using `graphql-request` with version lower than v4.0.0

An `AbortSignal` can be set in the `GraphQLClient` constructor.

[//]: # 'Example6'

```tsx
const query = useQuery({
  queryKey: ['todos'],
  queryFn: ({ signal }) => {
    const client = new GraphQLClient(endpoint, {
      signal,
    })
    return client.request(query, variables)
  },
})
```

[//]: # 'Example6'

## Manual Cancellation

You might want to cancel a query manually. For example, if the request takes a long time to finish, you can allow the user to click a cancel button to stop the request. To do this, you just need to call `queryClient.cancelQueries({ queryKey })`, which will cancel the query and revert it back to its previous state. If you have consumed the `signal` passed to the query function, TanStack Query will additionally also cancel the Promise.

[//]: # 'Example7'

```tsx
const query = useQuery({
  queryKey: ['todos'],
  queryFn: async ({ signal }) => {
    const resp = await fetch('/todos', { signal })
    return resp.json()
  },
})

const queryClient = useQueryClient()

return (
  <button
    onClick={(e) => {
      e.preventDefault()
      queryClient.cancelQueries({ queryKey: ['todos'] })
    }}
  >
    Cancel
  </button>
)
```

[//]: # 'Example7'

## Limitations

Cancelation does not work when working with `Suspense` hooks: `useSuspenseQuery`, `useSuspenseQueries` and `useSuspenseInfiniteQuery`.

---

# query-functions


---
id: query-functions
title: Query Functions
---

A query function can be literally any function that **returns a promise**. The promise that is returned should either **resolve the data** or **throw an error**.

All of the following are valid query function configurations:

[//]: # 'Example'

```tsx
useQuery({ queryKey: ['todos'], queryFn: fetchAllTodos })
useQuery({ queryKey: ['todos', todoId], queryFn: () => fetchTodoById(todoId) })
useQuery({
  queryKey: ['todos', todoId],
  queryFn: async () => {
    const data = await fetchTodoById(todoId)
    return data
  },
})
useQuery({
  queryKey: ['todos', todoId],
  queryFn: ({ queryKey }) => fetchTodoById(queryKey[1]),
})
```

[//]: # 'Example'

## Handling and Throwing Errors

For TanStack Query to determine a query has errored, the query function **must throw** or return a **rejected Promise**. Any error that is thrown in the query function will be persisted on the `error` state of the query.

[//]: # 'Example2'

```tsx
const { error } = useQuery({
  queryKey: ['todos', todoId],
  queryFn: async () => {
    if (somethingGoesWrong) {
      throw new Error('Oh no!')
    }
    if (somethingElseGoesWrong) {
      return Promise.reject(new Error('Oh no!'))
    }

    return data
  },
})
```

[//]: # 'Example2'

## Usage with `fetch` and other clients that do not throw by default

While most utilities like `axios` or `graphql-request` automatically throw errors for unsuccessful HTTP calls, some utilities like `fetch` do not throw errors by default. If that's the case, you'll need to throw them on your own. Here is a simple way to do that with the popular `fetch` API:

[//]: # 'Example3'

```tsx
useQuery({
  queryKey: ['todos', todoId],
  queryFn: async () => {
    const response = await fetch('/todos/' + todoId)
    if (!response.ok) {
      throw new Error('Network response was not ok')
    }
    return response.json()
  },
})
```

[//]: # 'Example3'

## Query Function Variables

Query keys are not just for uniquely identifying the data you are fetching, but are also conveniently passed into your query function as part of the QueryFunctionContext. While not always necessary, this makes it possible to extract your query functions if needed:

[//]: # 'Example4'

```tsx
function Todos({ status, page }) {
  const result = useQuery({
    queryKey: ['todos', { status, page }],
    queryFn: fetchTodoList,
  })
}

// Access the key, status and page variables in your query function!
function fetchTodoList({ queryKey }) {
  const [_key, { status, page }] = queryKey
  return new Promise()
}
```

[//]: # 'Example4'

### QueryFunctionContext

The `QueryFunctionContext` is the object passed to each query function. It consists of:

- `queryKey: QueryKey`: [Query Keys](../query-keys)
- `signal?: AbortSignal`
  - [AbortSignal](https://developer.mozilla.org/en-US/docs/Web/API/AbortSignal) instance provided by TanStack Query
  - Can be used for [Query Cancellation](../query-cancellation)
- `meta: Record<string, unknown> | undefined`
  - an optional field you can fill with additional information about your query

Additionally, [Infinite Queries](../infinite-queries) get the following options passed:

- `pageParam: TPageParam`
  - the page parameter used to fetch the current page
- `direction: 'forward' | 'backward'`
  - **deprecated**
  - the direction of the current page fetch
  - To get access to the direction of the current page fetch, please add a direction to `pageParam` from `getNextPageParam` and `getPreviousPageParam`.

---

# query-invalidation


---
id: query-invalidation
title: Query Invalidation
---

Waiting for queries to become stale before they are fetched again doesn't always work, especially when you know for a fact that a query's data is out of date because of something the user has done. For that purpose, the `QueryClient` has an `invalidateQueries` method that lets you intelligently mark queries as stale and potentially refetch them too!

[//]: # 'Example'

```tsx
// Invalidate every query in the cache
queryClient.invalidateQueries()
// Invalidate every query with a key that starts with `todos`
queryClient.invalidateQueries({ queryKey: ['todos'] })
```

[//]: # 'Example'

> Note: Where other libraries that use normalized caches would attempt to update local queries with the new data either imperatively or via schema inference, TanStack Query gives you the tools to avoid the manual labor that comes with maintaining normalized caches and instead prescribes **targeted invalidation, background-refetching and ultimately atomic updates**.

When a query is invalidated with `invalidateQueries`, two things happen:

- It is marked as stale. This stale state overrides any `staleTime` configurations being used in `useQuery` or related hooks
- If the query is currently being rendered via `useQuery` or related hooks, it will also be refetched in the background

## Query Matching with `invalidateQueries`

When using APIs like `invalidateQueries` and `removeQueries` (and others that support partial query matching), you can match multiple queries by their prefix, or get really specific and match an exact query. For information on the types of filters you can use, please see [Query Filters](../filters#query-filters).

In this example, we can use the `todos` prefix to invalidate any queries that start with `todos` in their query key:

[//]: # 'Example2'

```tsx
import { useQuery, useQueryClient } from '@tanstack/react-query'

// Get QueryClient from the context
const queryClient = useQueryClient()

queryClient.invalidateQueries({ queryKey: ['todos'] })

// Both queries below will be invalidated
const todoListQuery = useQuery({
  queryKey: ['todos'],
  queryFn: fetchTodoList,
})
const todoListQuery = useQuery({
  queryKey: ['todos', { page: 1 }],
  queryFn: fetchTodoList,
})
```

[//]: # 'Example2'

You can even invalidate queries with specific variables by passing a more specific query key to the `invalidateQueries` method:

[//]: # 'Example3'

```tsx
queryClient.invalidateQueries({
  queryKey: ['todos', { type: 'done' }],
})

// The query below will be invalidated
const todoListQuery = useQuery({
  queryKey: ['todos', { type: 'done' }],
  queryFn: fetchTodoList,
})

// However, the following query below will NOT be invalidated
const todoListQuery = useQuery({
  queryKey: ['todos'],
  queryFn: fetchTodoList,
})
```

[//]: # 'Example3'

The `invalidateQueries` API is very flexible, so even if you want to **only** invalidate `todos` queries that don't have any more variables or subkeys, you can pass an `exact: true` option to the `invalidateQueries` method:

[//]: # 'Example4'

```tsx
queryClient.invalidateQueries({
  queryKey: ['todos'],
  exact: true,
})

// The query below will be invalidated
const todoListQuery = useQuery({
  queryKey: ['todos'],
  queryFn: fetchTodoList,
})

// However, the following query below will NOT be invalidated
const todoListQuery = useQuery({
  queryKey: ['todos', { type: 'done' }],
  queryFn: fetchTodoList,
})
```

[//]: # 'Example4'

If you find yourself wanting **even more** granularity, you can pass a predicate function to the `invalidateQueries` method. This function will receive each `Query` instance from the query cache and allow you to return `true` or `false` for whether you want to invalidate that query:

[//]: # 'Example5'

```tsx
queryClient.invalidateQueries({
  predicate: (query) =>
    query.queryKey[0] === 'todos' && query.queryKey[1]?.version >= 10,
})

// The query below will be invalidated
const todoListQuery = useQuery({
  queryKey: ['todos', { version: 20 }],
  queryFn: fetchTodoList,
})

// The query below will be invalidated
const todoListQuery = useQuery({
  queryKey: ['todos', { version: 10 }],
  queryFn: fetchTodoList,
})

// However, the following query below will NOT be invalidated
const todoListQuery = useQuery({
  queryKey: ['todos', { version: 5 }],
  queryFn: fetchTodoList,
})
```

[//]: # 'Example5'

---

# query-keys


---
id: query-keys
title: Query Keys
---

At its core, TanStack Query manages query caching for you based on query keys. Query keys have to be an Array at the top level, and can be as simple as an Array with a single string, or as complex as an array of many strings and nested objects. As long as the query key is serializable, and **unique to the query's data**, you can use it!

## Simple Query Keys

The simplest form of a key is an array with constants values. This format is useful for:

- Generic List/Index resources
- Non-hierarchical resources

[//]: # 'Example'

```tsx
// A list of todos
useQuery({ queryKey: ['todos'], ... })

// Something else, whatever!
useQuery({ queryKey: ['something', 'special'], ... })
```

[//]: # 'Example'

## Array Keys with variables

When a query needs more information to uniquely describe its data, you can use an array with a string and any number of serializable objects to describe it. This is useful for:

- Hierarchical or nested resources
  - It's common to pass an ID, index, or other primitive to uniquely identify the item
- Queries with additional parameters
  - It's common to pass an object of additional options

[//]: # 'Example2'

```tsx
// An individual todo
useQuery({ queryKey: ['todo', 5], ... })

// An individual todo in a "preview" format
useQuery({ queryKey: ['todo', 5, { preview: true }], ...})

// A list of todos that are "done"
useQuery({ queryKey: ['todos', { type: 'done' }], ... })
```

[//]: # 'Example2'

## Query Keys are hashed deterministically!

This means that no matter the order of keys in objects, all of the following queries are considered equal:

[//]: # 'Example3'

```tsx
useQuery({ queryKey: ['todos', { status, page }], ... })
useQuery({ queryKey: ['todos', { page, status }], ...})
useQuery({ queryKey: ['todos', { page, status, other: undefined }], ... })
```

[//]: # 'Example3'

The following query keys, however, are not equal. Array item order matters!

[//]: # 'Example4'

```tsx
useQuery({ queryKey: ['todos', status, page], ... })
useQuery({ queryKey: ['todos', page, status], ...})
useQuery({ queryKey: ['todos', undefined, page, status], ...})
```

[//]: # 'Example4'

## If your query function depends on a variable, include it in your query key

Since query keys uniquely describe the data they are fetching, they should include any variables you use in your query function that **change**. For example:

[//]: # 'Example5'

```tsx
function Todos({ todoId }) {
  const result = useQuery({
    queryKey: ['todos', todoId],
    queryFn: () => fetchTodoById(todoId),
  })
}
```

[//]: # 'Example5'

Note that query keys act as dependencies for your query functions. Adding dependent variables to your query key will ensure that queries are cached independently, and that any time a variable changes, _queries will be refetched automatically_ (depending on your `staleTime` settings). See the [exhaustive-deps](../../../../eslint/exhaustive-deps) section for more information and examples.

[//]: # 'Materials'

## Further reading

For tips on organizing Query Keys in larger applications, have a look at [Effective React Query Keys](../../community/tkdodos-blog#8-effective-react-query-keys) and check the [Query Key Factory Package](../../community/community-projects#query-key-factory) from
the Community Resources.

[//]: # 'Materials'

---

# query-options


---
id: query-options
title: Query Options
---

One of the best ways to share `queryKey` and `queryFn` between multiple places, yet keep them co-located to one another, is to use the `queryOptions` helper. At runtime, this helper just returns whatever you pass into it, but it has a lot of advantages when using it [with TypeScript](../../typescript#typing-query-options). You can define all possible options for a query in one place, and you'll also get type inference and type safety for all of them.

[//]: # 'Example1'

```ts
import { queryOptions } from '@tanstack/react-query'

function groupOptions(id: number) {
  return queryOptions({
    queryKey: ['groups', id],
    queryFn: () => fetchGroups(id),
    staleTime: 5 * 1000,
  })
}

// usage:

useQuery(groupOptions(1))
useSuspenseQuery(groupOptions(5))
useQueries({
  queries: [groupOptions(1), groupOptions(2)],
})
queryClient.prefetchQuery(groupOptions(23))
queryClient.setQueryData(groupOptions(42).queryKey, newGroups)
```

[//]: # 'Example1'

For Infinite Queries, a separate [`infiniteQueryOptions`](../reference/infiniteQueryOptions.md) helper is available.

---

# query-retries


---
id: query-retries
title: Query Retries
---

When a `useQuery` query fails (the query function throws an error), TanStack Query will automatically retry the query if that query's request has not reached the max number of consecutive retries (defaults to `3`) or a function is provided to determine if a retry is allowed.

You can configure retries both on a global level and an individual query level.

- Setting `retry = false` will disable retries.
- Setting `retry = 6` will retry failing requests 6 times before showing the final error thrown by the function.
- Setting `retry = true` will infinitely retry failing requests.
- Setting `retry = (failureCount, error) => ...` allows for custom logic based on why the request failed.

[//]: # 'Info'

> On the server, retries default to `0` to make server rendering as fast as possible.

[//]: # 'Info'
[//]: # 'Example'

```tsx
import { useQuery } from '@tanstack/react-query'

// Make a specific query retry a certain number of times
const result = useQuery({
  queryKey: ['todos', 1],
  queryFn: fetchTodoListPage,
  retry: 10, // Will retry failed requests 10 times before displaying an error
})
```

[//]: # 'Example'

> Info: Contents of the `error` property will be part of `failureReason` response property of `useQuery` until the last retry attempt. So in above example any error contents will be part of `failureReason` property for first 9 retry attempts (Overall 10 attempts) and finally they will be part of `error` after last attempt if error persists after all retry attempts.

## Retry Delay

By default, retries in TanStack Query do not happen immediately after a request fails. As is standard, a back-off delay is gradually applied to each retry attempt.

The default `retryDelay` is set to double (starting at `1000`ms) with each attempt, but not exceed 30 seconds:

[//]: # 'Example2'

```tsx
// Configure for all queries
import {
  QueryCache,
  QueryClient,
  QueryClientProvider,
} from '@tanstack/react-query'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retryDelay: (attemptIndex) => Math.min(1000 * 2 ** attemptIndex, 30000),
    },
  },
})

function App() {
  return <QueryClientProvider client={queryClient}>...</QueryClientProvider>
}
```

[//]: # 'Example2'

Though it is not recommended, you can obviously override the `retryDelay` function/integer in both the Provider and individual query options. If set to an integer instead of a function the delay will always be the same amount of time:

[//]: # 'Example3'

```tsx
const result = useQuery({
  queryKey: ['todos'],
  queryFn: fetchTodoList,
  retryDelay: 1000, // Will always wait 1000ms to retry, regardless of how many retries
})
```

[//]: # 'Example3'

---

# render-optimizations


---
id: render-optimizations
title: Render Optimizations
---

React Query applies a couple of optimizations automatically to ensure that your components only re-render when they actually need to. This is done by the following means:

## structural sharing

React Query uses a technique called "structural sharing" to ensure that as many references as possible will be kept intact between re-renders. If data is fetched over the network, usually, you'll get a completely new reference by json parsing the response. However, React Query will keep the original reference if _nothing_ changed in the data. If a subset changed, React Query will keep the unchanged parts and only replace the changed parts.

> Note: This optimization only works if the `queryFn` returns JSON compatible data. You can turn it off by setting `structuralSharing: false` globally or on a per-query basis, or you can implement your own structural sharing by passing a function to it.

### referential identity

The top level object returned from `useQuery`, `useInfiniteQuery`, `useMutation` and the Array returned from `useQueries` is **not referentially stable**. It will be a new reference on every render. However, the `data` properties returned from these hooks will be as stable as possible.

## tracked properties

React Query will only trigger a re-render if one of the properties returned from `useQuery` is actually "used". This is done by using [custom getters](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Object/defineProperty#custom_setters_and_getters). This avoids a lot of unnecessary re-renders, e.g. because properties like `isFetching` or `isStale` might change often, but are not used in the component.

You can customize this feature by setting `notifyOnChangeProps` manually globally or on a per-query basis. If you want to turn that feature off, you can set `notifyOnChangeProps: 'all'`.

> Note: Custom getters are invoked by accessing a property, either via destructuring or by accessing it directly. If you use object rest destructuring, you will disable this optimization. We have a [lint rule](../../../../eslint/no-rest-destructuring) to guard against this pitfall.

## select

You can use the `select` option to select a subset of the data that your component should subscribe to. This is useful for highly optimized data transformations or to avoid unnecessary re-renders.

```js
export const useTodos = (select) => {
  return useQuery({
    queryKey: ['todos'],
    queryFn: fetchTodos,
    select,
  })
}

export const useTodoCount = () => {
  return useTodos((data) => data.length)
}
```

A component using the `useTodoCount` custom hook will only re-render if the length of the todos changes. It will **not** re-render if e.g. the name of a todo changed.

> Note: `select` operates on successfully cached data and is not the appropriate place to throw errors. The source of truth for errors is the `queryFn`, and a `select` function that returns an error results in `data` being `undefined` and `isSuccess` being `true`. We recommend handling errors in the `queryFn` if you wish to have a query fail on incorrect data, or outside of the query hook if you have a error case not related to caching.

### memoization

The `select` function will only re-run if:

- the `select` function itself changed referentially
- `data` changed

This means that an inlined `select` function, as shown above, will run on every render. To avoid this, you can wrap the `select` function in `useCallback`, or extract it to a stable function reference if it doesn't have any dependencies:

```js
// wrapped in useCallback
export const useTodoCount = () => {
  return useTodos(useCallback((data) => data.length, []))
}
```

```js
// extracted to a stable function reference
const selectTodoCount = (data) => data.length

export const useTodoCount = () => {
  return useTodos(selectTodoCount)
}
```

## Further Reading

For an in-depth guide about these topics, read [React Query Render Optimizations](../../community/tkdodos-blog#3-react-query-render-optimizations) from
the Community Resources.

---

# request-waterfalls


---
id: request-waterfalls
title: Performance & Request Waterfalls
---

Application performance is a broad and complex area and while React Query can't make your APIs faster, there are still things to be mindful about in how you use React Query to ensure the best performance.

The biggest performance footgun when using React Query, or indeed any data fetching library that lets you fetch data inside of components, is request waterfalls. The rest of this page will explain what they are, how you can spot them and how you can restructure your application or APIs to avoid them.

The [Prefetching & Router Integration guide](../prefetching) builds on this and teaches you how to prefetch data ahead of time when it's not possible or feasible to restructure your application or APIs.

The [Server Rendering & Hydration guide](../ssr) teaches you how to prefetch data on the server and pass that data down to the client so you don't have to fetch it again.

The [Advanced Server Rendering guide](../advanced-ssr) further teaches you how to apply these patterns to Server Components and Streaming Server Rendering.

## What is a Request Waterfall?

A request waterfall is what happens when a request for a resource (code, css, images, data) does not start until _after_ another request for a resource has finished.

Consider a web page. Before you can load things like the CSS, JS etc, the browser first needs to load the markup. This is a request waterfall.

```
1. |-> Markup
2.   |-> CSS
2.   |-> JS
2.   |-> Image
```

If you fetch your CSS inside a JS file, you now have a double waterfall:

```
1. |-> Markup
2.   |-> JS
3.     |-> CSS
```

If that CSS uses a background image, it's a triple waterfall:

```
1. |-> Markup
2.   |-> JS
3.     |-> CSS
4.       |-> Image
```

The best way to spot and analyze your request waterfalls is usually by opening your browsers devtools "Network" tab.

Each waterfall represents at least one roundtrip to the server, unless the resource is locally cached (in practice, some of these waterfalls might represent more than one roundtrip because the browser needs to establish a connection which requires some back and forth, but let's ignore that here). Because of this, the negative effects of request waterfalls are highly dependent on the users latency. Consider the example of the triple waterfall, which actually represents 4 server roundtrips. With 250ms latency, which is not uncommon on 3g networks or in bad network conditions, we end up with a total time of 4\*250=1000ms **only counting latency**. If we were able to flatten that to the first example with only 2 roundtrips, we get 500ms instead, possibly loading that background image in half the time!

## Request Waterfalls & React Query

Now let's consider React Query. We'll focus on the case without Server Rendering first. Before we can even start making a query, we need to load the JS, so before we can show that data on the screen, we have a double waterfall:

```
1. |-> Markup
2.   |-> JS
3.     |-> Query
```

With this as a basis, let's look at a few different patterns that can lead to Request Waterfalls in React Query, and how to avoid them.

- Single Component Waterfalls / Serial Queries
- Nested Component Waterfalls
- Code Splitting

### Single Component Waterfalls / Serial Queries

When a single component first fetches one query, and then another, that's a request waterfall. This can happen when the second query is a [Dependent Query](../dependent-queries), that is, it depends on data from the first query when fetching:

```tsx
// Get the user
const { data: user } = useQuery({
  queryKey: ['user', email],
  queryFn: getUserByEmail,
})

const userId = user?.id

// Then get the user's projects
const {
  status,
  fetchStatus,
  data: projects,
} = useQuery({
  queryKey: ['projects', userId],
  queryFn: getProjectsByUser,
  // The query will not execute until the userId exists
  enabled: !!userId,
})
```

While not always feasible, for optimal performance it's better to restructure your API so you can fetch both of these in a single query. In the example above, instead of first fetching `getUserByEmail` to be able to `getProjectsByUser`, introducing a new `getProjectsByUserEmail` query would flatten the waterfall.

> Another way to mitigate dependent queries without restructuring your API is to move the waterfall to the server where latency is lower. This is the idea behind Server Components which are covered in the [Advanced Server Rendering guide](../advanced-ssr).

Another example of serial queries is when you use React Query with Suspense:

```tsx
function App () {
  // The following queries will execute in serial, causing separate roundtrips to the server:
  const usersQuery = useSuspenseQuery({ queryKey: ['users'], queryFn: fetchUsers })
  const teamsQuery = useSuspenseQuery({ queryKey: ['teams'], queryFn: fetchTeams })
  const projectsQuery = useSuspenseQuery({ queryKey: ['projects'], queryFn: fetchProjects })

  // Note that since the queries above suspend rendering, no data
  // gets rendered until all of the queries finished
  ...
}
```

Note that with regular `useQuery` these would happen in parallel.

Luckily, this is easy to fix, by always using the hook `useSuspenseQueries` when you have multiple suspenseful queries in a component.

```tsx
const [usersQuery, teamsQuery, projectsQuery] = useSuspenseQueries({
  queries: [
    { queryKey: ['users'], queryFn: fetchUsers },
    { queryKey: ['teams'], queryFn: fetchTeams },
    { queryKey: ['projects'], queryFn: fetchProjects },
  ],
})
```

### Nested Component Waterfalls

Nested Component Waterfalls is when both a parent and a child component contains queries, and the parent does not render the child until its query is done. This can happen both with `useQuery` and `useSuspenseQuery`.

If the child renders conditionally based on the data in the parent, or if the child relies on some part of the result being passed down as a prop from the parent to make its query, we have a _dependent_ nested component waterfall.

Let's first look at an example where the child is **not** dependent on the parent.

```tsx
function Article({ id }) {
  const { data: articleData, isPending } = useQuery({
    queryKey: ['article', id],
    queryFn: getArticleById,
  })

  if (isPending) {
    return 'Loading article...'
  }

  return (
    <>
      <ArticleHeader articleData={articleData} />
      <ArticleBody articleData={articleData} />
      <Comments id={id} />
    </>
  )

}

function Comments({ id }) {
  const { data, isPending } = useQuery({
    queryKey: ['article-comments', id],
    queryFn: getArticleCommentsById,
  })

  ...
}
```

Note that while `<Comments>` takes a prop `id` from the parent, that id is already available when the `<Article>` renders so there is no reason we could not fetch the comments at the same time as the article. In real world applications, the child might be nested far below the parent and these kinds of waterfalls are often trickier to spot and fix, but for our example, one way to flatten the waterfall would be to hoist the comments query to the parent instead:

```tsx
function Article({ id }) {
  const { data: articleData, isPending: articlePending } = useQuery({
    queryKey: ['article', id],
    queryFn: getArticleById,
  })

  const { data: commentsData, isPending: commentsPending } = useQuery({
    queryKey: ['article-comments', id],
    queryFn: getArticleCommentsById,
  })

  if (articlePending) {
    return 'Loading article...'
  }

  return (
    <>
      <ArticleHeader articleData={articleData} />
      <ArticleBody articleData={articleData} />
      {commentsPending ? (
        'Loading comments...'
      ) : (
        <Comments commentsData={commentsData} />
      )}
    </>
  )
}
```

The two queries will now fetch in parallel. Note that if you are using suspense, you'd want to combine these two queries into a single `useSuspenseQueries` instead.

Another way to flatten this waterfall would be to prefetch the comments in the `<Article>` component, or prefetch both of these queries at the router level on page load or page navigation, read more about this in the [Prefetching & Router Integration guide](../prefetching).

Next, let's look at a _Dependent Nested Component Waterfall_.

```tsx
function Feed() {
  const { data, isPending } = useQuery({
    queryKey: ['feed'],
    queryFn: getFeed,
  })

  if (isPending) {
    return 'Loading feed...'
  }

  return (
    <>
      {data.map((feedItem) => {
        if (feedItem.type === 'GRAPH') {
          return <GraphFeedItem key={feedItem.id} feedItem={feedItem} />
        }

        return <StandardFeedItem key={feedItem.id} feedItem={feedItem} />
      })}
    </>
  )
}

function GraphFeedItem({ feedItem }) {
  const { data, isPending } = useQuery({
    queryKey: ['graph', feedItem.id],
    queryFn: getGraphDataById,
  })

  ...
}
```

The second query `getGraphDataById` is dependent on it's parent in two different ways. First of all, it doesn't ever happen unless the `feedItem` is a graph, and second, it needs an `id` from the parent.

```
1. |> getFeed()
2.   |> getGraphDataById()
```

In this example, we can't trivially flatten the waterfall by just hoisting the query to the parent, or even adding prefetching. Just like the dependent query example at the beginning of this guide, one option is to refactor our API to include the graph data in the `getFeed` query. Another more advanced solution is to leverage Server Components to move the waterfall to the server where latency is lower (read more about this in the [Advanced Server Rendering guide](../advanced-ssr)) but note that this can be a very big architectural change.

You can have good performance even with a few query waterfalls here and there, just know they are a common performance concern and be mindful about them. An especially insidious version is when Code Splitting is involved, let's take a look at this next.

### Code Splitting

Splitting an applications JS-code into smaller chunks and only loading the necessary parts is usually a critical step in achieving good performance. It does have a downside however, in that it often introduces request waterfalls. When that code split code also has a query inside it, this problem is worsened further.

Consider this a slightly modified version of the Feed example.

```tsx
// This lazy loads the GraphFeedItem component, meaning
// it wont start loading until something renders it
const GraphFeedItem = React.lazy(() => import('./GraphFeedItem'))

function Feed() {
  const { data, isPending } = useQuery({
    queryKey: ['feed'],
    queryFn: getFeed,
  })

  if (isPending) {
    return 'Loading feed...'
  }

  return (
    <>
      {data.map((feedItem) => {
        if (feedItem.type === 'GRAPH') {
          return <GraphFeedItem key={feedItem.id} feedItem={feedItem} />
        }

        return <StandardFeedItem key={feedItem.id} feedItem={feedItem} />
      })}
    </>
  )
}

// GraphFeedItem.tsx
function GraphFeedItem({ feedItem }) {
  const { data, isPending } = useQuery({
    queryKey: ['graph', feedItem.id],
    queryFn: getGraphDataById,
  })

  ...
}
```

This example has a double waterfall, looking like this:

```
1. |> getFeed()
2.   |> JS for <GraphFeedItem>
3.     |> getGraphDataById()
```

But that's just looking at the code from the example, if we consider what the first page load of this page looks like, we actually have to complete 5 round trips to the server before we can render the graph!

```
1. |> Markup
2.   |> JS for <Feed>
3.     |> getFeed()
4.       |> JS for <GraphFeedItem>
5.         |> getGraphDataById()
```

Note that this looks a bit different when server rendering, we will explore that further in the [Server Rendering & Hydration guide](../ssr). Also note that it's not uncommon for the route that contains `<Feed>` to also be code split, which could add yet another hop.

In the code split case, it might actually help to hoist the `getGraphDataById` query to the `<Feed>` component and make it conditional, or add a conditional prefetch. That query could then be fetched in parallel with the code, turning the example part into this:

```
1. |> getFeed()
2.   |> getGraphDataById()
2.   |> JS for <GraphFeedItem>
```

This is very much a tradeoff however. You are now including the data fetching code for `getGraphDataById` in the same bundle as `<Feed>`, so evaluate what is best for your case. Read more about how to do this in the [Prefetching & Router Integration guide](../prefetching).

> The tradeoff between:
>
> - Include all data fetching code in the main bundle, even if we seldom use it
> - Put the data fetching code in the code split bundle, but with a request waterfall
>
> is not great and has been one of the motivations for Server Components. With Server Components, it's possible to avoid both, read more about how this applies to React Query in the [Advanced Server Rendering guide](../advanced-ssr).

## Summary and takeaways

Request Waterfalls are a very common and complex performance concern with many tradeoffs. There are many ways to accidentally introduce them into your application:

- Adding a query to a child, not realizing a parent already has a query
- Adding a query to a parent, not realizing a child already has a query
- Moving a component with descendants that has a query to a new parent with an ancestor that has a query
- Etc..

Because of this accidental complexity, it pays off to be mindful of waterfalls and regularly examine your application looking for them (a good way is to examine the Network tab every now and then!). You don't necessarily have to flatten them all to have good performance, but keep an eye out for the high impact ones.

In the next guide, we'll look at more ways to flatten waterfalls, by leveraging [Prefetching & Router Integration](../prefetching).

---

# scroll-restoration


---
id: scroll-restoration
title: Scroll Restoration
---

Traditionally, when you navigate to a previously visited page on a web browser, you would find that the page would be scrolled to the exact position where you were before you navigated away from that page. This is called **scroll restoration** and has been in a bit of a regression since web applications have started moving towards client side data fetching. With TanStack Query however, that's no longer the case.

Out of the box, "scroll restoration" for all queries (including paginated and infinite queries) Just Works™️ in TanStack Query. The reason for this is that query results are cached and able to be retrieved synchronously when a query is rendered. As long as your queries are being cached long enough (the default time is 5 minutes) and have not been garbage collected, scroll restoration will work out of the box all the time.

---

# ssr


---
id: ssr
title: Server Rendering & Hydration
---

In this guide you'll learn how to use React Query with server rendering.

See the guide on [Prefetching & Router Integration](../prefetching) for some background. You might also want to check out the [Performance & Request Waterfalls guide](../request-waterfalls) before that.

For advanced server rendering patterns, such as streaming, Server Components and the new Next.js app router, see the [Advanced Server Rendering guide](../advanced-ssr).

If you just want to see some code, you can skip ahead to the [Full Next.js pages router example](#full-nextjs-pages-router-example) or the [Full Remix example](#full-remix-example) below.

## Server Rendering & React Query

So what is server rendering anyway? The rest of this guide will assume you are familiar with the concept, but let's spend some time to look at how it relates to React Query. Server rendering is the act of generating the initial html on the server, so that the user has some content to look at as soon as the page loads. This can happen on demand when a page is requested (SSR). It can also happen ahead of time either because a previous request was cached, or at build time (SSG).

If you've read the Request Waterfalls guide, you might remember this:

```
1. |-> Markup (without content)
2.   |-> JS
3.     |-> Query
```

With a client rendered application, these are the minimum 3 server roundtrips you will need to make before getting any content on the screen for the user. One way of viewing server rendering is that it turns the above into this:

```
1. |-> Markup (with content AND initial data)
2.   |-> JS
```

As soon as **1.** is complete, the user can see the content and when **2.** finishes, the page is interactive and clickable. Because the markup also contains the initial data we need, step **3.** does not need to run on the client at all, at least until you want to revalidate the data for some reason.

This is all from the clients perspective. On the server, we need to **prefetch** that data before we generate/render the markup, we need to **dehydrate** that data into a serializable format we can embed in the markup, and on the client we need to **hydrate** that data into a React Query cache so we can avoid doing a new fetch on the client.

Read on to learn how to implement these three steps with React Query.

## A quick note on Suspense

This guide uses the regular `useQuery` API. While we don't necessarily recommend it, it is possible to replace this with `useSuspenseQuery` instead **as long as you always prefetch all your queries**. The upside is that you get to use `<Suspense>` for loading states on the client.

If you do forget to prefetch a query when you are using `useSuspenseQuery`, the consequences will depend on the framework you are using. In some cases, the data will Suspend and get fetched on the server but never be hydrated to the client, where it will fetch again. In these cases you will get a markup hydration mismatch, because the server and the client tried to render different things.

## Initial setup

The first steps of using React Query is always to create a `queryClient` and wrap the application in a `<QueryClientProvider>`. When doing server rendering, it's important to create the `queryClient` instance **inside of your app**, in React state (an instance ref works fine too). **This ensures that data is not shared between different users and requests**, while still only creating the `queryClient` once per component lifecycle.

Next.js pages router:

```tsx
// _app.tsx
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// NEVER DO THIS:
// const queryClient = new QueryClient()
//
// Creating the queryClient at the file root level makes the cache shared
// between all requests and means _all_ data gets passed to _all_ users.
// Besides being bad for performance, this also leaks any sensitive data.

export default function MyApp({ Component, pageProps }) {
  // Instead do this, which ensures each request has its own cache:
  const [queryClient] = React.useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // With SSR, we usually want to set some default staleTime
            // above 0 to avoid refetching immediately on the client
            staleTime: 60 * 1000,
          },
        },
      }),
  )

  return (
    <QueryClientProvider client={queryClient}>
      <Component {...pageProps} />
    </QueryClientProvider>
  )
}
```

Remix:

```tsx
// app/root.tsx
import { Outlet } from '@remix-run/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

export default function MyApp() {
  const [queryClient] = React.useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // With SSR, we usually want to set some default staleTime
            // above 0 to avoid refetching immediately on the client
            staleTime: 60 * 1000,
          },
        },
      }),
  )

  return (
    <QueryClientProvider client={queryClient}>
      <Outlet />
    </QueryClientProvider>
  )
}
```

## Get started fast with `initialData`

The quickest way to get started is to not involve React Query at all when it comes to prefetching and not use the `dehydrate`/`hydrate` APIs. What you do instead is passing the raw data in as the `initialData` option to `useQuery`. Let's look at an example using Next.js pages router, using `getServerSideProps`.

```tsx
export async function getServerSideProps() {
  const posts = await getPosts()
  return { props: { posts } }
}

function Posts(props) {
  const { data } = useQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
    initialData: props.posts,
  })

  // ...
}
```

This also works with `getStaticProps` or even the older `getInitialProps` and the same pattern can be applied in any other framework that has equivalent functions. This is what the same example looks like with Remix:

```tsx
export async function loader() {
  const posts = await getPosts()
  return json({ posts })
}

function Posts() {
  const { posts } = useLoaderData<typeof loader>()

  const { data } = useQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
    initialData: posts,
  })

  // ...
}
```

The setup is minimal and this can be a quick solution for some cases, but there are a **few tradeoffs to consider** when compared to the full approach:

- If you are calling `useQuery` in a component deeper down in the tree you need to pass the `initialData` down to that point
- If you are calling `useQuery` with the same query in multiple locations, passing `initialData` to only one of them can be brittle and break when your app changes since. If you remove or move the component that has the `useQuery` with `initialData`, the more deeply nested `useQuery` might no longer have any data. Passing `initialData` to **all** queries that needs it can also be cumbersome.
- There is no way to know at what time the query was fetched on the server, so `dataUpdatedAt` and determining if the query needs refetching is based on when the page loaded instead
- If there is already data in the cache for a query, `initialData` will never overwrite this data, **even if the new data is fresher than the old one**.
  - To understand why this is especially bad, consider the `getServerSideProps` example above. If you navigate back and forth to a page several times, `getServerSideProps` would get called each time and fetch new data, but because we are using the `initialData` option, the client cache and data would never be updated.

Setting up the full hydration solution is straightforward and does not have these drawbacks, this will be the focus for the rest of the documentation.

## Using the Hydration APIs

With just a little more setup, you can use a `queryClient` to prefetch queries during a preload phase, pass a serialized version of that `queryClient` to the rendering part of the app and reuse it there. This avoid the drawbacks above. Feel free to skip ahead for full Next.js pages router and Remix examples, but at a general level these are the extra steps:

- In the framework loader function, create a `const queryClient = new QueryClient(options)`
- In the loader function, do `await queryClient.prefetchQuery(...)` for each query you want to prefetch
  - You want to use `await Promise.all(...)` to fetch the queries in parallel when possible
  - It's fine to have queries that aren't prefetched. These wont be server rendered, instead they will be fetched on the client after the application is interactive. This can be great for content that are shown only after user interaction, or is far down on the page to avoid blocking more critical content.
- From the loader, return `dehydrate(queryClient)`, note that the exact syntax to return this differs between frameworks
- Wrap your tree with `<HydrationBoundary state={dehydratedState}>` where `dehydratedState` comes from the framework loader. How you get `dehydratedState` also differs between frameworks.
  - This can be done for each route, or at the top of the application to avoid boilerplate, see examples

> An interesting detail is that there are actually _three_ `queryClient`s involved. The framework loaders are a form of "preloading" phase that happens before rendering, and this phase has its own `queryClient` that does the prefetching. The dehydrated result of this phase gets passed to **both** the server rendering process **and** the client rendering process which each has its own `queryClient`. This ensures they both start with the same data so they can return the same markup.

> Server Components are another form of "preloading" phase, that can also "preload" (pre-render) parts of a React component tree. Read more in the [Advanced Server Rendering guide](../advanced-ssr).

### Full Next.js pages router example

> For app router documentation, see the [Advanced Server Rendering guide](../advanced-ssr).

Initial setup:

```tsx
// _app.tsx
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

export default function MyApp({ Component, pageProps }) {
  const [queryClient] = React.useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // With SSR, we usually want to set some default staleTime
            // above 0 to avoid refetching immediately on the client
            staleTime: 60 * 1000,
          },
        },
      }),
  )

  return (
    <QueryClientProvider client={queryClient}>
      <Component {...pageProps} />
    </QueryClientProvider>
  )
}
```

In each route:

```tsx
// pages/posts.tsx
import {
  dehydrate,
  HydrationBoundary,
  QueryClient,
  useQuery,
} from '@tanstack/react-query'

// This could also be getServerSideProps
export async function getStaticProps() {
  const queryClient = new QueryClient()

  await queryClient.prefetchQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
  })

  return {
    props: {
      dehydratedState: dehydrate(queryClient),
    },
  }
}

function Posts() {
  // This useQuery could just as well happen in some deeper child to
  // the <PostsRoute>, data will be available immediately either way
  const { data } = useQuery({ queryKey: ['posts'], queryFn: getPosts })

  // This query was not prefetched on the server and will not start
  // fetching until on the client, both patterns are fine to mix
  const { data: commentsData } = useQuery({
    queryKey: ['posts-comments'],
    queryFn: getComments,
  })

  // ...
}

export default function PostsRoute({ dehydratedState }) {
  return (
    <HydrationBoundary state={dehydratedState}>
      <Posts />
    </HydrationBoundary>
  )
}
```

### Full Remix example

Initial setup:

```tsx
// app/root.tsx
import { Outlet } from '@remix-run/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

export default function MyApp() {
  const [queryClient] = React.useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            // With SSR, we usually want to set some default staleTime
            // above 0 to avoid refetching immediately on the client
            staleTime: 60 * 1000,
          },
        },
      }),
  )

  return (
    <QueryClientProvider client={queryClient}>
      <Outlet />
    </QueryClientProvider>
  )
}
```

In each route, note that it's fine to do this in nested routes too:

```tsx
// app/routes/posts.tsx
import { json } from '@remix-run/node'
import {
  dehydrate,
  HydrationBoundary,
  QueryClient,
  useQuery,
} from '@tanstack/react-query'

export async function loader() {
  const queryClient = new QueryClient()

  await queryClient.prefetchQuery({
    queryKey: ['posts'],
    queryFn: getPosts,
  })

  return json({ dehydratedState: dehydrate(queryClient) })
}

function Posts() {
  // This useQuery could just as well happen in some deeper child to
  // the <PostsRoute>, data will be available immediately either way
  const { data } = useQuery({ queryKey: ['posts'], queryFn: getPosts })

  // This query was not prefetched on the server and will not start
  // fetching until on the client, both patterns are fine to mix
  const { data: commentsData } = useQuery({
    queryKey: ['posts-comments'],
    queryFn: getComments,
  })

  // ...
}

export default function PostsRoute() {
  const { dehydratedState } = useLoaderData<typeof loader>()
  return (
    <HydrationBoundary state={dehydratedState}>
      <Posts />
    </HydrationBoundary>
  )
}
```

## Optional - Remove boilerplate

Having this part in every route might seem like a lot of boilerplate:

```tsx
export default function PostsRoute({ dehydratedState }) {
  return (
    <HydrationBoundary state={dehydratedState}>
      <Posts />
    </HydrationBoundary>
  )
}
```

While there is nothing wrong with this approach, if you want to get rid of this boilerplate, here's how you can modify your setup in Next.js:

```tsx
// _app.tsx
import {
  HydrationBoundary,
  QueryClient,
  QueryClientProvider,
} from '@tanstack/react-query'

export default function MyApp({ Component, pageProps }) {
  const [queryClient] = React.useState(() => new QueryClient())

  return (
    <QueryClientProvider client={queryClient}>
      <HydrationBoundary state={pageProps.dehydratedState}>
        <Component {...pageProps} />
      </HydrationBoundary>
    </QueryClientProvider>
  )
}

// pages/posts.tsx
// Remove PostsRoute with the HydrationBoundary and instead export Posts directly:
export default function Posts() { ... }
```

With Remix, this is a little bit more involved, we recommend checking out the [use-dehydrated-state](https://github.com/maplegrove-io/use-dehydrated-state) package.

## Prefetching dependent queries

Over in the Prefetching guide we learned how to [prefetch dependent queries](../prefetching#dependent-queries--code-splitting), but how do we do this in framework loaders? Consider the following code, taken from the [Dependent Queries guide](../dependent-queries):

```tsx
// Get the user
const { data: user } = useQuery({
  queryKey: ['user', email],
  queryFn: getUserByEmail,
})

const userId = user?.id

// Then get the user's projects
const {
  status,
  fetchStatus,
  data: projects,
} = useQuery({
  queryKey: ['projects', userId],
  queryFn: getProjectsByUser,
  // The query will not execute until the userId exists
  enabled: !!userId,
})
```

How would we prefetch this so it can be server rendered? Here's an example:

```tsx
// For Remix, rename this to loader instead
export async function getServerSideProps() {
  const queryClient = new QueryClient()

  const user = await queryClient.fetchQuery({
    queryKey: ['user', email],
    queryFn: getUserByEmail,
  })

  if (user?.userId) {
    await queryClient.prefetchQuery({
      queryKey: ['projects', userId],
      queryFn: getProjectsByUser,
    })
  }

  // For Remix:
  // return json({ dehydratedState: dehydrate(queryClient) })
  return { props: { dehydratedState: dehydrate(queryClient) } }
}
```

This can get more complex of course, but since these loader functions are just JavaScript, you can use the full power of the language to build your logic. Make sure you prefetch all queries that you want to be server rendered.

## Error handling

React Query defaults to a graceful degradation strategy. This means:

- `queryClient.prefetchQuery(...)` never throws errors
- `dehydrate(...)` only includes successful queries, not failed ones

This will lead to any failed queries being retried on the client and that the server rendered output will include loading states instead of the full content.

While a good default, sometimes this is not what you want. When critical content is missing, you might want to respond with a 404 or 500 status code depending on the situation. For these cases, use `queryClient.fetchQuery(...)` instead, which will throw errors when it fails, letting you handle things in a suitable way.

```tsx
let result

try {
  result = await queryClient.fetchQuery(...)
} catch (error) {
  // Handle the error, refer to your framework documentation
}

// You might also want to check and handle any invalid `result` here
```

If you for some reason want to include failed queries in the dehydrated state to avoid retries, you can use the option `shouldDehydrateQuery` to override the default function and implement your own logic:

```tsx
dehydrate(queryClient, {
  shouldDehydrateQuery: (query) => {
    // This will include all queries, including failed ones,
    // but you can also implement your own logic by inspecting `query`
    return true
  },
})
```

## Serialization

When doing `return { props: { dehydratedState: dehydrate(queryClient) } }` in Next.js, or `return json({ dehydratedState: dehydrate(queryClient) })` in Remix, what happens is that the `dehydratedState` representation of the `queryClient` is serialized by the framework so it can be embedded into the markup and transported to the client.

By default, these frameworks only supports returning things that are safely serializable/parsable, and therefore does not support `undefined`, `Error`, `Date`, `Map`, `Set`, `BigInt`, `Infinity`, `NaN`, `-0`, regular expressions etc. This also means that you can not return any of these things from your queries. If returning these values is something you want, check out [superjson](https://github.com/blitz-js/superjson) or similar packages.

If you are using a custom SSR setup, you need to take care of this step yourself. Your first instinct might be to use `JSON.stringify(dehydratedState)`, but because this doesn't escape things like `<script>alert('Oh no..')</script>` by default, this can easily lead to **XSS-vulnerabilities** in your application. [superjson](https://github.com/blitz-js/superjson) also **does not** escape values and is unsafe to use by itself in a custom SSR setup (unless you add an extra step for escaping the output). Instead we recommend using a library like [Serialize JavaScript](https://github.com/yahoo/serialize-javascript) or [devalue](https://github.com/Rich-Harris/devalue) which are both safe against XSS injections out of the box.

## A note about request waterfalls

In the [Performance & Request Waterfalls guide](../request-waterfalls) we mentioned we would revisit how server rendering changes one of the more complex nested waterfalls. Check back for the [specific code example](../request-waterfalls#code-splitting), but as a refresher, we have a code split `<GraphFeedItem>` component inside a `<Feed>` component. This only renders if the feed contains a graph item and both of these components fetches their own data. With client rendering, this leads to the following request waterfall:

```
1. |> Markup (without content)
2.   |> JS for <Feed>
3.     |> getFeed()
4.       |> JS for <GraphFeedItem>
5.         |> getGraphDataById()
```

The nice thing about server rendering is that we can turn the above into:

```
1. |> Markup (with content AND initial data)
2.   |> JS for <Feed>
2.   |> JS for <GraphFeedItem>
```

Note that the queries are no longer fetched on the client, instead their data was included in the markup. The reason we can now load the JS in parallel is that since `<GraphFeedItem>` was rendered on the server we know that we are going to need this JS on the client as well and can insert a script-tag for this chunk in the markup. On the server, we would still have this request waterfall:

```
1. |> getFeed()
2.   |> getGraphDataById()
```

We simply can not know before we have fetched the feed if we also need to fetch graph data, they are dependent queries. Because this happens on the server where latency is generally both lower and more stable, this often isn't such a big deal.

Amazing, we've mostly flattened our waterfalls! There's a catch though. Let's call this page the `/feed` page, and let's pretend we also have another page like `/posts`. If we type in `www.example.com/feed` directly in the url bar and hit enter, we get all these great server rendering benefits, BUT, if we instead type in `www.example.com/posts` and then **click a link** to `/feed`, we're back to to this:

```
1. |> JS for <Feed>
2.   |> getFeed()
3.     |> JS for <GraphFeedItem>
4.       |> getGraphDataById()
```

This is because with SPA's, server rendering only works for the initial page load, not for any subsequent navigation.

Modern frameworks often try to solve this by fetching the initial code and data in parallel, so if you were using Next.js or Remix with the prefetching patterns we outlined in this guide, including how to prefetch dependent queries, it would actually look like this instead:

```
1. |> JS for <Feed>
1. |> getFeed() + getGraphDataById()
2.   |> JS for <GraphFeedItem>
```

This is much better, but if we want to improve this further we can flatten this to a single roundtrip with Server Components. Learn how in the [Advanced Server Rendering guide](../advanced-ssr).

## Tips, Tricks and Caveats

### Staleness is measured from when the query was fetched on the server

A query is considered stale depending on when it was `dataUpdatedAt`. A caveat here is that the server needs to have the correct time for this to work properly, but UTC time is used, so timezones do not factor into this.

Because `staleTime` defaults to `0`, queries will be refetched in the background on page load by default. You might want to use a higher `staleTime` to avoid this double fetching, especially if you don't cache your markup.

This refetching of stale queries is a perfect match when caching markup in a CDN! You can set the cache time of the page itself decently high to avoid having to re-render pages on the server, but configure the `staleTime` of the queries lower to make sure data is refetched in the background as soon as a user visits the page. Maybe you want to cache the pages for a week, but refetch the data automatically on page load if it's older than a day?

### High memory consumption on server

In case you are creating the `QueryClient` for every request, React Query creates the isolated cache for this client, which is preserved in memory for the `gcTime` period. That may lead to high memory consumption on server in case of high number of requests during that period.

On the server, `gcTime` defaults to `Infinity` which disables manual garbage collection and will automatically clear memory once a request has finished. If you are explicitly setting a non-Infinity `gcTime` then you will be responsible for clearing the cache early.

Avoid setting `gcTime` to `0` as it may result in a hydration error. This occurs because the [Hydration Boundary](../../reference/hydration#hydrationboundary) places necessary data into the cache for rendering, but if the garbage collector removes the data before the rendering completes, issues may arise. If you require a shorter `gcTime`, we recommend setting it to `2 * 1000` to allow sufficient time for the app to reference the data.

To clear the cache after it is not needed and to lower memory consumption, you can add a call to [`queryClient.clear()`](../../../../reference/QueryClient/#queryclientclear) after the request is handled and dehydrated state has been sent to the client.

Alternatively, you can set a smaller `gcTime`.

### Caveat for Next.js rewrites

There's a catch if you're using [Next.js' rewrites feature](https://nextjs.org/docs/api-reference/next.config.js/rewrites) together with [Automatic Static Optimization](https://nextjs.org/docs/advanced-features/automatic-static-optimization) or `getStaticProps`: It will cause a second hydration by React Query. That's because [Next.js needs to ensure that they parse the rewrites](https://nextjs.org/docs/api-reference/next.config.js/rewrites#rewrite-parameters) on the client and collect any params after hydration so that they can be provided in `router.query`.

The result is missing referential equality for all the hydration data, which for example triggers wherever your data is used as props of components or in the dependency array of `useEffect`s/`useMemo`s.

---

# suspense


---
id: suspense
title: Suspense
---

React Query can also be used with React's Suspense for Data Fetching API's. For this, we have dedicated hooks:

- [useSuspenseQuery](../../reference/useSuspenseQuery)
- [useSuspenseInfiniteQuery](../../reference/useSuspenseInfiniteQuery)
- [useSuspenseQueries](../../reference/useSuspenseQueries)
- Additionally, you can use the `useQuery().promise` and `React.use()` (Experimental)

When using suspense mode, `status` states and `error` objects are not needed and are then replaced by usage of the `React.Suspense` component (including the use of the `fallback` prop and React error boundaries for catching errors). Please read the [Resetting Error Boundaries](#resetting-error-boundaries) and look at the [Suspense Example](https://stackblitz.com/github/TanStack/query/tree/main/examples/react/suspense) for more information on how to set up suspense mode.

If you want mutations to propagate errors to the nearest error boundary (similar to queries), you can set the `throwOnError` option to `true` as well.

Enabling suspense mode for a query:

```tsx
import { useSuspenseQuery } from '@tanstack/react-query'

const { data } = useSuspenseQuery({ queryKey, queryFn })
```

This works nicely in TypeScript, because `data` is guaranteed to be defined (as errors and loading states are handled by Suspense- and ErrorBoundaries).

On the flip side, you therefore can't conditionally enable / disable the Query. This generally shouldn't be necessary for dependent Queries because with suspense, all your Queries inside one component are fetched in serial.

`placeholderData` also doesn't exist for this Query. To prevent the UI from being replaced by a fallback during an update, wrap your updates that change the QueryKey into [startTransition](https://react.dev/reference/react/Suspense#preventing-unwanted-fallbacks).

### throwOnError default

Not all errors are thrown to the nearest Error Boundary per default - we're only throwing errors if there is no other data to show. That means if a Query ever successfully got data in the cache, the component will render, even if data is `stale`. Thus, the default for `throwOnError` is:

```
throwOnError: (error, query) => typeof query.state.data === 'undefined'
```

Since you can't change `throwOnError` (because it would allow for `data` to become potentially `undefined`), you have to throw errors manually if you want all errors to be handled by Error Boundaries:

```tsx
import { useSuspenseQuery } from '@tanstack/react-query'

const { data, error, isFetching } = useSuspenseQuery({ queryKey, queryFn })

if (error && !isFetching) {
  throw error
}

// continue rendering data
```

## Resetting Error Boundaries

Whether you are using **suspense** or **throwOnError** in your queries, you will need a way to let queries know that you want to try again when re-rendering after some error occurred.

Query errors can be reset with the `QueryErrorResetBoundary` component or with the `useQueryErrorResetBoundary` hook.

When using the component it will reset any query errors within the boundaries of the component:

```tsx
import { QueryErrorResetBoundary } from '@tanstack/react-query'
import { ErrorBoundary } from 'react-error-boundary'

const App = () => (
  <QueryErrorResetBoundary>
    {({ reset }) => (
      <ErrorBoundary
        onReset={reset}
        fallbackRender={({ resetErrorBoundary }) => (
          <div>
            There was an error!
            <Button onClick={() => resetErrorBoundary()}>Try again</Button>
          </div>
        )}
      >
        <Page />
      </ErrorBoundary>
    )}
  </QueryErrorResetBoundary>
)
```

When using the hook it will reset any query errors within the closest `QueryErrorResetBoundary`. If there is no boundary defined it will reset them globally:

```tsx
import { useQueryErrorResetBoundary } from '@tanstack/react-query'
import { ErrorBoundary } from 'react-error-boundary'

const App = () => {
  const { reset } = useQueryErrorResetBoundary()
  return (
    <ErrorBoundary
      onReset={reset}
      fallbackRender={({ resetErrorBoundary }) => (
        <div>
          There was an error!
          <Button onClick={() => resetErrorBoundary()}>Try again</Button>
        </div>
      )}
    >
      <Page />
    </ErrorBoundary>
  )
}
```

## Fetch-on-render vs Render-as-you-fetch

Out of the box, React Query in `suspense` mode works really well as a **Fetch-on-render** solution with no additional configuration. This means that when your components attempt to mount, they will trigger query fetching and suspend, but only once you have imported them and mounted them. If you want to take it to the next level and implement a **Render-as-you-fetch** model, we recommend implementing [Prefetching](../prefetching) on routing callbacks and/or user interactions events to start loading queries before they are mounted and hopefully even before you start importing or mounting their parent components.

## Suspense on the Server with streaming

If you are using `NextJs`, you can use our **experimental** integration for Suspense on the Server: `@tanstack/react-query-next-experimental`. This package will allow you to fetch data on the server (in a client component) by just calling `useSuspenseQuery` in your component. Results will then be streamed from the server to the client as SuspenseBoundaries resolve.

To achieve this, wrap your app in the `ReactQueryStreamedHydration` component:

```tsx
// app/providers.tsx
'use client'

import {
  isServer,
  QueryClient,
  QueryClientProvider,
} from '@tanstack/react-query'
import * as React from 'react'
import { ReactQueryStreamedHydration } from '@tanstack/react-query-next-experimental'

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        // With SSR, we usually want to set some default staleTime
        // above 0 to avoid refetching immediately on the client
        staleTime: 60 * 1000,
      },
    },
  })
}

let browserQueryClient: QueryClient | undefined = undefined

function getQueryClient() {
  if (isServer) {
    // Server: always make a new query client
    return makeQueryClient()
  } else {
    // Browser: make a new query client if we don't already have one
    // This is very important, so we don't re-make a new client if React
    // suspends during the initial render. This may not be needed if we
    // have a suspense boundary BELOW the creation of the query client
    if (!browserQueryClient) browserQueryClient = makeQueryClient()
    return browserQueryClient
  }
}

export function Providers(props: { children: React.ReactNode }) {
  // NOTE: Avoid useState when initializing the query client if you don't
  //       have a suspense boundary between this and the code that may
  //       suspend because React will throw away the client on the initial
  //       render if it suspends and there is no boundary
  const queryClient = getQueryClient()

  return (
    <QueryClientProvider client={queryClient}>
      <ReactQueryStreamedHydration>
        {props.children}
      </ReactQueryStreamedHydration>
    </QueryClientProvider>
  )
}
```

For more information, check out the [NextJs Suspense Streaming Example](../../examples/nextjs-suspense-streaming) and the [Advanced Rendering & Hydration](../advanced-ssr) guide.

## Using `useQuery().promise` and `React.use()` (Experimental)

> To enable this feature, you need to set the `experimental_prefetchInRender` option to `true` when creating your `QueryClient`

**Example code:**

```tsx
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      experimental_prefetchInRender: true,
    },
  },
})
```

**Usage:**

```tsx
import React from 'react'
import { useQuery } from '@tanstack/react-query'
import { fetchTodos, type Todo } from './api'

function TodoList({ query }: { query: UseQueryResult<Todo[]> }) {
  const data = React.use(query.promise)

  return (
    <ul>
      {data.map((todo) => (
        <li key={todo.id}>{todo.title}</li>
      ))}
    </ul>
  )
}

export function App() {
  const query = useQuery({ queryKey: ['todos'], queryFn: fetchTodos })

  return (
    <>
      <h1>Todos</h1>
      <React.Suspense fallback={<div>Loading...</div>}>
        <TodoList query={query} />
      </React.Suspense>
    </>
  )
}
```

---

# testing


---
id: testing
title: Testing
---

React Query works by means of hooks - either the ones we offer or custom ones that wrap around them.

With React 17 or earlier, writing unit tests for these custom hooks can be done by means of the [React Hooks Testing Library](https://react-hooks-testing-library.com/) library.

Install this by running:

```sh
npm install @testing-library/react-hooks react-test-renderer --save-dev
```

(The `react-test-renderer` library is needed as a peer dependency of `@testing-library/react-hooks`, and needs to correspond to the version of React that you are using.)

_Note_: when using React 18 or later, `renderHook` is available directly through the `@testing-library/react` package, and `@testing-library/react-hooks` is no longer required.

## Our First Test

Once installed, a simple test can be written. Given the following custom hook:

```tsx
export function useCustomHook() {
  return useQuery({ queryKey: ['customHook'], queryFn: () => 'Hello' })
}
```

Using React 17 or earlier, we can write a test for this as follows:

```tsx
const queryClient = new QueryClient()
const wrapper = ({ children }) => (
  <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
)

const { result, waitFor } = renderHook(() => useCustomHook(), { wrapper })

await waitFor(() => result.current.isSuccess)

expect(result.current.data).toEqual('Hello')
```

Using React 18 or later, the semantics of `waitFor` have changed, and the above test needs to be modified as follows:

```tsx
import { renderHook, waitFor } from "@testing-library/react";

...

const { result } = renderHook(() => useCustomHook(), { wrapper });

await waitFor(() => expect(result.current.isSuccess).toBe(true));
```

Note that we provide a custom wrapper that builds the `QueryClient` and `QueryClientProvider`. This helps to ensure that our test is completely isolated from any other tests.

It is possible to write this wrapper only once, but if so we need to ensure that the `QueryClient` gets cleared before every test, and that tests don't run in parallel otherwise one test will influence the results of others.

## Turn off retries

The library defaults to three retries with exponential backoff, which means that your tests are likely to timeout if you want to test an erroneous query. The easiest way to turn retries off is via the QueryClientProvider. Let's extend the above example:

```tsx
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // ✅ turns retries off
      retry: false,
    },
  },
})
const wrapper = ({ children }) => (
  <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
)
```

This will set the defaults for all queries in the component tree to "no retries". It is important to know that this will only work if your actual useQuery has no explicit retries set. If you have a query that wants 5 retries, this will still take precedence, because defaults are only taken as a fallback.

## Set gcTime to Infinity with Jest

If you use Jest, you can set the `gcTime` to `Infinity` to prevent "Jest did not exit one second after the test run completed" error message. This is the default behavior on the server, and is only necessary to set if you are explicitly setting a `gcTime`.

## Testing Network Calls

The primary use for React Query is to cache network requests, so it's important that we can test our code is making the correct network requests in the first place.

There are plenty of ways that these can be tested, but for this example we are going to use [nock](https://www.npmjs.com/package/nock).

Given the following custom hook:

```tsx
function useFetchData() {
  return useQuery({
    queryKey: ['fetchData'],
    queryFn: () => request('/api/data'),
  })
}
```

We can write a test for this as follows:

```tsx
const queryClient = new QueryClient()
const wrapper = ({ children }) => (
  <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
)

const expectation = nock('http://example.com').get('/api/data').reply(200, {
  answer: 42,
})

const { result, waitFor } = renderHook(() => useFetchData(), { wrapper })

await waitFor(() => {
  return result.current.isSuccess
})

expect(result.current.data).toEqual({ answer: 42 })
```

Here we are making use of `waitFor` and waiting until the query status indicates that the request has succeeded. This way we know that our hook has finished and should have the correct data. _Note_: when using React 18, the semantics of `waitFor` have changed as noted above.

## Testing Load More / Infinite Scroll

First we need to mock our API response

```tsx
function generateMockedResponse(page) {
  return {
    page: page,
    items: [...]
  }
}
```

Then, our `nock` configuration needs to differentiate responses based on the page, and we'll be using `uri` to do this.
`uri`'s value here will be something like `"/?page=1` or `/?page=2`

```tsx
const expectation = nock('http://example.com')
  .persist()
  .query(true)
  .get('/api/data')
  .reply(200, (uri) => {
    const url = new URL(`http://example.com${uri}`)
    const { page } = Object.fromEntries(url.searchParams)
    return generateMockedResponse(page)
  })
```

(Notice the `.persist()`, because we'll be calling from this endpoint multiple times)

Now we can safely run our tests, the trick here is to await for the data assertion to pass:

```tsx
const { result, waitFor } = renderHook(() => useInfiniteQueryCustomHook(), {
  wrapper,
})

await waitFor(() => result.current.isSuccess)

expect(result.current.data.pages).toStrictEqual(generateMockedResponse(1))

result.current.fetchNextPage()

await waitFor(() =>
  expect(result.current.data.pages).toStrictEqual([
    ...generateMockedResponse(1),
    ...generateMockedResponse(2),
  ]),
)

expectation.done()
```

_Note_: when using React 18, the semantics of `waitFor` have changed as noted above.

## Further reading

For additional tips and an alternative setup using `mock-service-worker`, have a look at [Testing React Query](../../community/tkdodos-blog#5-testing-react-query) from
the Community Resources.

---

# updates-from-mutation-responses


---
id: updates-from-mutation-responses
title: Updates from Mutation Responses
---

When dealing with mutations that **update** objects on the server, it's common for the new object to be automatically returned in the response of the mutation. Instead of refetching any queries for that item and wasting a network call for data we already have, we can take advantage of the object returned by the mutation function and update the existing query with the new data immediately using the [Query Client's `setQueryData`](../../../../reference/QueryClient/#queryclientsetquerydata) method:

[//]: # 'Example'

```tsx
const queryClient = useQueryClient()

const mutation = useMutation({
  mutationFn: editTodo,
  onSuccess: (data) => {
    queryClient.setQueryData(['todo', { id: 5 }], data)
  },
})

mutation.mutate({
  id: 5,
  name: 'Do the laundry',
})

// The query below will be updated with the response from the
// successful mutation
const { status, data, error } = useQuery({
  queryKey: ['todo', { id: 5 }],
  queryFn: fetchTodoById,
})
```

[//]: # 'Example'

You might want to tie the `onSuccess` logic into a reusable mutation, for that you can
create a custom hook like this:

[//]: # 'Example2'

```tsx
const useMutateTodo = () => {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: editTodo,
    // Notice the second argument is the variables object that the `mutate` function receives
    onSuccess: (data, variables) => {
      queryClient.setQueryData(['todo', { id: variables.id }], data)
    },
  })
}
```

[//]: # 'Example2'

## Immutability

Updates via `setQueryData` must be performed in an _immutable_ way. **DO NOT** attempt to write directly to the cache by mutating data (that you retrieved from the cache) in place. It might work at first but can lead to subtle bugs along the way.

[//]: # 'Example3'

```tsx
queryClient.setQueryData(['posts', { id }], (oldData) => {
  if (oldData) {
    // ❌ do not try this
    oldData.title = 'my new post title'
  }
  return oldData
})

queryClient.setQueryData(
  ['posts', { id }],
  // ✅ this is the way
  (oldData) =>
    oldData
      ? {
          ...oldData,
          title: 'my new post title',
        }
      : oldData,
)
```

[//]: # 'Example3'

---

# window-focus-refetching


---
id: window-focus-refetching
title: Window Focus Refetching
---

If a user leaves your application and returns and the query data is stale, **TanStack Query automatically requests fresh data for you in the background**. You can disable this globally or per-query using the `refetchOnWindowFocus` option:

#### Disabling Globally

[//]: # 'Example'

```tsx
//
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false, // default: true
    },
  },
})

function App() {
  return <QueryClientProvider client={queryClient}>...</QueryClientProvider>
}
```

[//]: # 'Example'

#### Disabling Per-Query

[//]: # 'Example2'

```tsx
useQuery({
  queryKey: ['todos'],
  queryFn: fetchTodos,
  refetchOnWindowFocus: false,
})
```

[//]: # 'Example2'

## Custom Window Focus Event

In rare circumstances, you may want to manage your own window focus events that trigger TanStack Query to revalidate. To do this, TanStack Query provides a `focusManager.setEventListener` function that supplies you the callback that should be fired when the window is focused and allows you to set up your own events. When calling `focusManager.setEventListener`, the previously set handler is removed (which in most cases will be the default handler) and your new handler is used instead. For example, this is the default handler:

[//]: # 'Example3'

```tsx
focusManager.setEventListener((handleFocus) => {
  // Listen to visibilitychange
  if (typeof window !== 'undefined' && window.addEventListener) {
    const visibilitychangeHandler = () => {
      handleFocus(document.visibilityState === 'visible')
    }
    window.addEventListener('visibilitychange', visibilitychangeHandler, false)
    return () => {
      // Be sure to unsubscribe if a new handler is set
      window.removeEventListener('visibilitychange', visibilitychangeHandler)
    }
  }
})
```

[//]: # 'Example3'
[//]: # 'ReactNative'

## Managing Focus in React Native

Instead of event listeners on `window`, React Native provides focus information through the [`AppState` module](https://reactnative.dev/docs/appstate#app-states). You can use the `AppState` "change" event to trigger an update when the app state changes to "active":

```tsx
import { AppState } from 'react-native'
import { focusManager } from '@tanstack/react-query'

function onAppStateChange(status: AppStateStatus) {
  if (Platform.OS !== 'web') {
    focusManager.setFocused(status === 'active')
  }
}

useEffect(() => {
  const subscription = AppState.addEventListener('change', onAppStateChange)

  return () => subscription.remove()
}, [])
```

[//]: # 'ReactNative'

## Managing focus state

[//]: # 'Example4'

```tsx
import { focusManager } from '@tanstack/react-query'

// Override the default focus state
focusManager.setFocused(true)

// Fallback to the default focus check
focusManager.setFocused(undefined)
```

[//]: # 'Example4'
