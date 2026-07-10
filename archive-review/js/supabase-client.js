const SUPABASE_URL = "https://axurevrvifolfdacpxuv.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF4dXJldnJ2aWZvbGZkYWNweHV2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM2MTgxMDYsImV4cCI6MjA5OTE5NDEwNn0.3EeKTJ7FVPXgtBFqqpQSNM-6wht9PhhlQhD3URUYIs4";
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const EMPLOYEES = [
  "강현성", "권석현", "김민우", "김민지", "김지윤",
  "박현준", "부석준", "이광원", "이수빈", "전수지",
  "정경환", "최영훈", "황태훈",
];
