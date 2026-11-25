# Deploy `paytrack-fe` lên Kubernetes

SPA Quasar (Vue 3) build tĩnh, phục vụ bằng nginx, nghe port `8080` trong pod. Hệ chỉ
có **một môi trường**: merge `main` sang nhánh `prod`, CI build và đẩy image lên GHCR,
rồi deploy vào namespace `paytrack`.

```
Merge main -> prod, push  -> Actions build + push ghcr.io/zerocompany-org/paytrack-fe/fe
                             tag: latest + sha-<short>
                          -> ./deploy.sh sha-<commit>
                          -> cụm pull image, rolling update
```

Kiến trúc request (**TLS terminate NGOÀI cụm**):

```
Client --HTTPS--> Traefik VPS (repo traefik-fpt) --HTTP--> NodePort 30080 --> Traefik cụm
      --> IngressRoute --> Service:8080 --> Pod:8080 (nginx)
```

**Repo `traefik-fpt` KHÔNG cần sửa gì**: router catch-all `k8s-default` đã hứng mọi
Host, và `*.zerornd.com` đã nằm trong `tls.domains` của router đó nên cert có sẵn.
Trình duyệt gọi thẳng API ở domain riêng (`api-paytrack.zerornd.com`), **không** proxy
qua nginx của FE; nginx ở đây chỉ phục vụ file tĩnh + SPA fallback.

## Hai điểm phải nhớ về FE này

### 1. `BASE_URL` được bake vào bundle lúc build

`src/boot/axios.js` dùng `process.env.BASE_URL`; `quasar.config.js` nạp `.env` qua
dotenv vào `build.env`, webpack thay biến đó thành **hằng số** trong bundle.
Dockerfile nhận `ARG BASE_URL` rồi ghi ra `.env` trước `yarn build`.

Hệ quả:

- Đổi endpoint API = **build lại image**, không phải sửa ConfigMap rồi restart.
- Giá trị lấy từ GitHub Actions Variable `BASE_URL` (Settings → Secrets and variables
  → Actions → Variables), vd `https://api-paytrack.zerornd.com/api`. Workflow fail sớm nếu
  thiếu, thay vì build ra image trỏ `localhost`.

### 2. Image KHÔNG tự có cấu hình nginx

`Dockerfile` xoá `/etc/nginx/conf.d/default.conf` của image gốc mà không copy file
nào vào thay (docker-compose bù bằng mount từ host). Trên k8s, ConfigMap
`paytrack-fe-nginx` (`nginx-config.yaml`) đóng vai trò đó — **thiếu nó nginx chạy
nhưng không phục vụ gì**.

Bản trong ConfigMap bám sát `nginx.conf` ở gốc repo, chỉ khác 2 điểm: `listen 8080`
(pod chạy non-root, không bind được cổng < 1024) và `error_log` mức `warn` thay vì
`debug`.

## Thiết lập 1 lần

### 1. Namespace

```bash
kubectl create -f namespace.yaml      # lần đầu dùng create, không dùng apply
```

Namespace `paytrack` **dùng chung** với API (`paytrack-be`). File này giống hệt bản ở
repo BE, chạy bên nào cũng được — nếu BE đã tạo rồi thì bỏ qua bước này.

Annotation trong file gán namespace vào Rancher Project **ZeroR&D-Common**
(`local:p-tbjsn`); thiếu nó thì tài khoản không có quyền tạo resource bên trong. Lý do
phải dùng `create` thay vì `apply` ở lần đầu: xem README của repo BE.

### 2. Secret pull image từ GHCR

```bash
kubectl -n paytrack create secret docker-registry ghcr-cred \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<PAT co read:packages>
```

Nếu đã tạo khi deploy BE vào cùng namespace thì **không cần làm lại**.

### 3. GitHub Actions Variable (làm ở repo, không phải trên cụm)

| Variable | Giá trị |
|---|---|
| `BASE_URL` | `https://api-paytrack.zerornd.com/api` |

Phải khớp `Host()` trong `ingressroute.yaml` của repo BE, và nhớ hậu tố `/api`.

### 4. Domain

`ingressroute.yaml` đang để `paytrack.zerornd.com`. Cert đã có sẵn nhờ SAN
`*.zerornd.com`; chỉ cần tạo **bản ghi DNS** trên Cloudflare trỏ về Traefik VPS
(zerornd.com không có wildcard DNS, phải khai từng bản ghi).

Domain này cũng phải khớp `webServer.clientAddr` trong `secret.yaml` của BE — giá trị
đó được nhúng vào link trong email thông báo payment.

### 5. Apply lần đầu

```bash
kubectl apply -k .
kubectl -n paytrack rollout status deployment/paytrack-fe
```

Khác repo BE: FE **không có file nào bị `.gitignore`**, clone về là `apply -k .`
chạy được ngay.

## Deploy thường ngày

```bash
git checkout prod && git merge main && git push origin prod   # Actions tự build
cd deploys/k8s && ./deploy.sh sha-<short-commit>
```

Rollback = `./deploy.sh sha-<tag truoc>` hoặc
`kubectl -n paytrack rollout undo deployment/paytrack-fe`. GHCR giữ 3 version nên lùi
được 2 bước.

Sửa cấu hình nginx:

```bash
vim nginx-config.yaml && kubectl apply -k .
kubectl -n paytrack rollout restart deployment/paytrack-fe   # BẮT BUỘC
```

ConfigMap đổi **không** tự làm pod nhận cấu hình mới.

## Thêm môi trường staging sau này

Copy thư mục này thành `stg/`, đổi namespace sang `stg-paytrack`, đổi domain, đổi
image sang package riêng `fe-stg`, rồi thêm `staging` vào `branches` trong
`.github/workflows/build-fe.yml` cùng một Variable `BASE_URL_STG` riêng (image
staging và production là hai bản build khác nhau vì `BASE_URL` bake lúc build).

## Hạn chế đã biết (của app, không phải của manifest)

| Vấn đề | Ảnh hưởng | Nếu muốn sửa |
|---|---|---|
| `src/helper/socket.js` hard-code `io('http://localhost:6789')`. | Socket.io không kết nối được khi chạy thật — các cập nhật realtime im lặng không chạy. Không cấu hình k8s nào cứu được. | Dựng URL từ `process.env.BASE_URL` (bỏ hậu tố `/api`) hoặc thêm biến `SOCKET_URL` vào `.env` + `build.env`, rồi khai thêm build-arg trong workflow. |
| `BASE_URL` bake lúc build. | Đổi domain API phải build lại image. | Chuyển sang nạp config runtime (vd fetch `/config.json` do ConfigMap cấp). |

## Gỡ rối

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| `Forbidden` khi apply | Namespace chưa tồn tại (lần đầu `kubectl create -f namespace.yaml`), hoặc tạo không kèm annotation `field.cattle.io/projectId` |
| `ImagePullBackOff` | Thiếu secret `ghcr-cred`, hoặc deploy tag `sha-*` mà workflow chưa build xong |
| Pod chạy nhưng mọi URL trả 404 của nginx | Thiếu ConfigMap `paytrack-fe-nginx` hoặc mount sai `subPath` — image không có server block mặc định |
| nginx `CrashLoopBackOff`, log `permission denied` ở `/var/run/nginx.pid` hoặc `/var/cache/nginx` | Thiếu 2 emptyDir `run` / `cache`, hoặc xoá mất `fsGroup: 101` |
| Trang load được nhưng request API lỗi `ERR_CONNECTION_REFUSED localhost:6789` | Image build thiếu Variable `BASE_URL` → rơi về default trong Dockerfile. Khai rồi build lại |
| Request API lỗi CORS | `Host()` của BE không khớp `BASE_URL` đã bake, hoặc có gắn thêm middleware cors của Traefik (BE đã tự set header CORS) |
| F5 ở route con trả 404 | `try_files ... /index.html` trong ConfigMap bị sửa mất |

Lệnh hay dùng:

```bash
kubectl -n paytrack get pod -l app=paytrack-fe
kubectl -n paytrack logs -l app=paytrack-fe --tail=100 -f
kubectl -n paytrack exec -it deploy/paytrack-fe -- cat /etc/nginx/conf.d/default.conf
kubectl -n paytrack exec -it deploy/paytrack-fe -- wget -qO- localhost:8080/health
```
