const MAX_DIMENSION = 1600;
const JPEG_QUALITY = 0.82;

function compressImage(file) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const url = URL.createObjectURL(file);
    img.onload = () => {
      URL.revokeObjectURL(url);
      let { width, height } = img;
      if (width > MAX_DIMENSION || height > MAX_DIMENSION) {
        if (width > height) {
          height = Math.round((height * MAX_DIMENSION) / width);
          width = MAX_DIMENSION;
        } else {
          width = Math.round((width * MAX_DIMENSION) / height);
          height = MAX_DIMENSION;
        }
      }
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      canvas.getContext("2d").drawImage(img, 0, 0, width, height);
      canvas.toBlob((blob) => resolve(blob), "image/jpeg", JPEG_QUALITY);
    };
    img.onerror = reject;
    img.src = url;
  });
}

async function startUpload() {
  const input = document.getElementById("file-input");
  const files = Array.from(input.files);
  if (!files.length) {
    alert("사진을 선택해주세요.");
    return;
  }

  const btn = document.getElementById("upload-btn");
  const progress = document.getElementById("progress");
  btn.disabled = true;

  let done = 0;
  let failed = 0;

  for (const file of files) {
    progress.textContent = `업로드 중... (${done + failed + 1}/${files.length})`;
    try {
      const blob = await compressImage(file);
      const path = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}.jpg`;
      const { error: uploadErr } = await sb.storage.from("archive-photos").upload(path, blob, {
        contentType: "image/jpeg",
      });
      if (uploadErr) throw uploadErr;

      const { data } = sb.storage.from("archive-photos").getPublicUrl(path);
      const { error: insertErr } = await sb
        .from("archive_photos")
        .insert({ storage_path: path, public_url: data.publicUrl });
      if (insertErr) throw insertErr;

      done++;
    } catch (e) {
      console.error(file.name, e);
      failed++;
    }
  }

  progress.textContent = `완료: ${done}장 성공${failed ? `, ${failed}장 실패` : ""}`;
  btn.disabled = false;
  input.value = "";
  loadExisting();
}

async function loadExisting() {
  const { data, error } = await sb
    .from("archive_photos")
    .select("id, public_url")
    .order("uploaded_at", { ascending: false })
    .limit(60);

  if (error) return;

  const { count } = await sb.from("archive_photos").select("id", { count: "exact", head: true });
  document.getElementById("existing-count").textContent = `현재 업로드된 사진: ${count ?? data.length}장 (최근 60장 미리보기)`;

  document.getElementById("thumbs").innerHTML = data
    .map((p) => `<img src="${p.public_url}" loading="lazy">`)
    .join("");
}

loadExisting();
