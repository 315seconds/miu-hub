const SUPABASE_URL = "https://rakfyvxpysmfuzkdoevc.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJha2Z5dnhweXNtZnV6a2RvZXZjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkzMjEyOTYsImV4cCI6MjEwNDg5NzI5Nn0.nEv6bpAmN7aIBy_ZWeyObSChidvGCE3XNlWR4SyjkZw";
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

async function sbUploadPhoto(hangerId, file) {
  const ext  = file.name.split(".").pop() || "jpg";
  const path = `${hangerId}/${Date.now()}.${ext}`;
  const { error } = await sb.storage.from("inventory-photos").upload(path, file, { upsert: true });
  if (error) throw new Error(error.message);
  const { data } = sb.storage.from("inventory-photos").getPublicUrl(path);
  return data.publicUrl;
}
