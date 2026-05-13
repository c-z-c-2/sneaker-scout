-- Sneaker Scout — full database schema
-- Run this against a fresh Supabase (or any Postgres) project to recreate the schema.
-- After running this, apply seed data from:
--   aussie-kicks-tracker/supabase/migrations/20250716112750-*.sql

-- ============================================================
-- Tables
-- ============================================================

CREATE TABLE public.brands (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at timestamptz DEFAULT now() NOT NULL,
  name       text        NOT NULL UNIQUE,
  logo_url   text
);

CREATE TABLE public.retailers (
  id          uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at  timestamptz DEFAULT now() NOT NULL,
  name        text        NOT NULL UNIQUE,
  logo_url    text,
  website_url text
);

CREATE TABLE public.sneakers (
  id           uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at   timestamptz DEFAULT now() NOT NULL,
  updated_at   timestamptz DEFAULT now() NOT NULL,
  brand_id     uuid        NOT NULL REFERENCES public.brands(id),
  name         text        NOT NULL,
  model        text        NOT NULL,
  description  text,
  release_date date,
  lookup_key   text        NOT NULL DEFAULT '',
  UNIQUE (brand_id, lookup_key)
);

CREATE TABLE public.colorways (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at timestamptz DEFAULT now() NOT NULL,
  sneaker_id uuid        NOT NULL REFERENCES public.sneakers(id),
  name       text        NOT NULL,
  color_code text,
  image_url  text,
  lookup_key text        NOT NULL DEFAULT '',
  UNIQUE (sneaker_id, lookup_key)
);

CREATE TABLE public.sizes (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at timestamptz DEFAULT now() NOT NULL,
  us_size    numeric     NOT NULL UNIQUE
);

CREATE TABLE public.prices (
  id             uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at     timestamptz DEFAULT now() NOT NULL,
  last_updated   timestamptz DEFAULT now() NOT NULL,
  colorway_id    uuid        NOT NULL REFERENCES public.colorways(id),
  retailer_id    uuid        NOT NULL REFERENCES public.retailers(id),
  price          numeric     NOT NULL,
  original_price numeric,
  currency       text,
  is_available   boolean,
  product_url    text,
  UNIQUE (colorway_id, retailer_id)
);

-- Append-only; a row is inserted whenever update_supabase_daily.py detects a price change
CREATE TABLE public.price_history (
  id          uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  recorded_at timestamptz DEFAULT now() NOT NULL,
  colorway_id uuid        NOT NULL REFERENCES public.colorways(id),
  retailer_id uuid        NOT NULL REFERENCES public.retailers(id),
  price       numeric     NOT NULL,
  currency    text
);

-- Availability of a specific size for a specific colorway at a specific retailer
CREATE TABLE public.sneaker_sizes (
  id           uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at   timestamptz DEFAULT now() NOT NULL,
  colorway_id  uuid        NOT NULL REFERENCES public.colorways(id),
  size_id      uuid        NOT NULL REFERENCES public.sizes(id),
  retailer_id  uuid        NOT NULL REFERENCES public.retailers(id),
  is_available boolean,
  UNIQUE (colorway_id, size_id, retailer_id)
);

CREATE TABLE public.profiles (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL,
  user_id    uuid        NOT NULL REFERENCES auth.users(id),
  first_name text,
  last_name  text,
  avatar_url text
);

CREATE TABLE public.user_favorites (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at timestamptz DEFAULT now() NOT NULL,
  user_id    uuid        NOT NULL,
  sneaker_id uuid        NOT NULL REFERENCES public.sneakers(id)
);

-- ============================================================
-- Row Level Security
-- ============================================================

ALTER TABLE public.brands         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retailers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sneakers       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.colorways      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sizes          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prices         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_history  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sneaker_sizes  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_favorites ENABLE ROW LEVEL SECURITY;

-- Sneaker catalogue: anyone can read (backend writes via service_role which bypasses RLS)
CREATE POLICY "Public read" ON public.brands        FOR SELECT USING (true);
CREATE POLICY "Public read" ON public.retailers     FOR SELECT USING (true);
CREATE POLICY "Public read" ON public.sneakers      FOR SELECT USING (true);
CREATE POLICY "Public read" ON public.colorways     FOR SELECT USING (true);
CREATE POLICY "Public read" ON public.sizes         FOR SELECT USING (true);
CREATE POLICY "Public read" ON public.prices        FOR SELECT USING (true);
CREATE POLICY "Public read" ON public.price_history FOR SELECT USING (true);
CREATE POLICY "Public read" ON public.sneaker_sizes FOR SELECT USING (true);

-- Profiles: authenticated user sees/edits only their own row
CREATE POLICY "Own profile read"   ON public.profiles FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Own profile insert" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Own profile update" ON public.profiles FOR UPDATE USING (auth.uid() = user_id);

-- Favourites: authenticated user manages only their own rows
CREATE POLICY "Own favorites read"   ON public.user_favorites FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Own favorites insert" ON public.user_favorites FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Own favorites delete" ON public.user_favorites FOR DELETE USING (auth.uid() = user_id);
