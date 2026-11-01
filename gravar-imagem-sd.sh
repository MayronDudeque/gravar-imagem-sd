#!/usr/bin/env bash
set -Eeuo pipefail
script_tmp="$(mktemp)"
trap 'rm -f -- "$script_tmp"' EXIT
cat > "$script_tmp" <<'PY'
#!/usr/bin/env python3
"""Busca uma imagem local, grava no SD USB e compara o SHA-256."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path, PurePosixPath

APP_LOCAL = Path("/media/p3/APP_local")
IMAGE_DIR = APP_LOCAL / "ImagemMetcore"
SCRIPT_PATH = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
IMAGE_EXTENSIONS = {".img", ".iso", ".raw", ".wic"}
ARCHIVE_EXTENSIONS = {".7z", ".zip"}


def fail(message):
    print(f"\nERRO: {message}", file=sys.stderr)
    raise SystemExit(1)


def fmt_size(size):
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{value:.1f} TB"


def ask_choice(items, prompt):
    for index, item in enumerate(items, 1):
        kind = item.get("kind", "imagem")
        path = item.get("path", item.get("member", ""))
        print(f"  {index}) [{kind}] {item['name']} — {fmt_size(item['size'])}")
        print(f"     {path}")
    while True:
        answer = input(prompt).strip()
        if answer.isdigit() and 1 <= int(answer) <= len(items):
            return items[int(answer) - 1]
        print(f"Digite um número entre 1 e {len(items)}.")


def scan_local_sources():
    sources = []
    for path in IMAGE_DIR.rglob("*"):
        if not path.is_file():
            continue
        if any(part.startswith(".gravar-imagem-") for part in path.relative_to(IMAGE_DIR).parts):
            continue
        suffix = path.suffix.lower()
        if suffix in IMAGE_EXTENSIONS or suffix in ARCHIVE_EXTENSIONS:
            kind = "imagem direta" if suffix in IMAGE_EXTENSIONS else f"arquivo {suffix}"
            sources.append({
                "name": path.name,
                "path": str(path.relative_to(IMAGE_DIR)),
                "source_path": path,
                "size": path.stat().st_size,
                "kind": kind,
                "suffix": suffix,
            })
    return sorted(sources, key=lambda item: item["path"].casefold())


def zip_images(archive_path):
    images = []
    with zipfile.ZipFile(archive_path) as archive:
        for info in archive.infolist():
            if info.is_dir():
                continue
            member = info.filename
            name = PurePosixPath(member.replace("\\", "/")).name
            if PurePosixPath(name).suffix.lower() in IMAGE_EXTENSIONS:
                images.append({"member": member, "name": name, "size": info.file_size})
    return images


def seven_zip_command():
    for candidate in ("7z", "7zz", "7za"):
        executable = shutil.which(candidate)
        if executable:
            return executable
    return None


def seven_zip_images(executable, archive_path):
    result = subprocess.run(
        [executable, "l", "-slt", str(archive_path)],
        text=True, encoding="utf-8", errors="replace",
        capture_output=True, check=False
    )
    if result.returncode != 0:
        fail("Não consegui listar o arquivo .7z: " + result.stderr.strip())

    images = []
    for block in result.stdout.split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if " = " in line:
                key, value = line.split(" = ", 1)
                fields[key] = value
        member = fields.get("Path")
        if not member or fields.get("Folder") == "+":
            continue
        name = PurePosixPath(member.replace("\\", "/")).name
        if PurePosixPath(name).suffix.lower() in IMAGE_EXTENSIONS:
            try:
                size = int(fields.get("Size", "0"))
            except ValueError:
                size = 0
            images.append({"member": member, "name": name, "size": size})
    return images


def extract_image(archive_path, suffix, selected_image, staging_dir, seven_zip):
    destination = Path(staging_dir) / selected_image["name"]
    if suffix == ".zip":
        with zipfile.ZipFile(archive_path) as archive:
            total = archive.getinfo(selected_image["member"]).file_size
            completed = 0
            started = time.monotonic()
            last_update = 0.0
            with archive.open(selected_image["member"]) as source, open(destination, "wb") as output:
                while True:
                    chunk = source.read(4 * 1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    completed += len(chunk)
                    last_update = show_progress(
                        "Descompactação ZIP", completed, total, started, last_update
                    )
            show_progress(
                "Descompactação ZIP", completed, total, started, last_update,
                force=True, complete=True
            )
            print()
    elif suffix == ".7z":
        print("Descompactando .7z; o percentual será exibido pelo 7-Zip...")
        result = subprocess.run(
            [seven_zip, "e", "-y", "-bsp1", f"-o{staging_dir}",
             str(archive_path), selected_image["member"]],
            check=False
        )
        if result.returncode != 0:
            fail("Falha ao extrair o arquivo .7z. Confira as mensagens exibidas pelo 7-Zip.")
    else:
        fail("Formato compactado não suportado.")
    if not destination.is_file() or destination.stat().st_size == 0:
        fail("A imagem extraída está vazia ou não foi encontrada.")
    return destination


def device_list():
    result = subprocess.run(
        ["lsblk", "--json", "--paths", "--bytes", "--output", "NAME,SIZE,TYPE,TRAN,RM,MODEL"],
        text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        fail("Não consegui listar os dispositivos com lsblk.")
    rows = json.loads(result.stdout).get("blockdevices", [])
    choices = []
    for row in rows:
        if row.get("type") != "disk":
            continue
        removable = row.get("rm", False)
        if isinstance(removable, str):
            removable = removable.lower() in ("1", "true", "yes")
        else:
            removable = bool(removable)
        if row.get("tran") == "usb" or removable:
            choices.append({
                "name": row["name"],
                "size": int(row.get("size") or 0),
                "model": row.get("model") or "modelo não informado",
            })
    return choices


def block_tree(device):
    result = subprocess.run(
        ["lsblk", "--json", "--paths", "--output", "NAME,TYPE,MOUNTPOINT", device],
        text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        fail("Não consegui ler as partições do dispositivo.")
    return json.loads(result.stdout).get("blockdevices", [])


def walk_nodes(nodes):
    for node in nodes:
        yield node
        yield from walk_nodes(node.get("children", []))


def settle_devices():
    """Espera o kernel terminar de atualizar a tabela de partições."""
    udevadm = shutil.which("udevadm")
    if udevadm:
        subprocess.run([udevadm, "settle"], check=False)


def unmount_device(device, fail_on_error=True, settle=True):
    """Desmonta todas as partições atualmente montadas no dispositivo."""
    if settle:
        settle_devices()
    nodes = list(walk_nodes(block_tree(device)))
    for node in reversed(nodes):
        mount = node.get("mountpoint")
        if not mount:
            continue
        print(f"Desmontando {node['name']} ({mount})...")
        result = subprocess.run(["sudo", "umount", node["name"]], check=False)
        if result.returncode != 0:
            message = f"Não foi possível desmontar {node['name']}. Feche programas que usem o cartão."
            if fail_on_error:
                fail(message)
            print(f"AVISO: {message}", file=sys.stderr)


def stop_automount():
    """Bloqueia temporariamente novas regras udev, inclusive automontagem."""
    udevadm = shutil.which("udevadm")
    if not udevadm:
        fail("O comando udevadm não foi encontrado; não é seguro gravar com automontagem ativa.")

    # Primeiro deixa eventos pendentes terminarem; depois bloqueia novos
    # eventos enquanto o dispositivo está sendo regravado.
    settle_devices()
    result = subprocess.run(
        ["sudo", udevadm, "control", "--stop-exec-queue"],
        text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        fail(
            "Não consegui bloquear temporariamente a automontagem: "
            + (result.stderr.strip() or "erro desconhecido")
        )
    return udevadm


def start_automount(udevadm):
    """Libera novamente as regras udev após o dispositivo estar desligado."""
    result = subprocess.run(
        ["sudo", udevadm, "control", "--start-exec-queue"],
        text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        print(
            "AVISO: não consegui reativar as regras udev: "
            + (result.stderr.strip() or "erro desconhecido"),
            file=sys.stderr,
        )
        return False
    settle_devices()
    print("Automontagem reativada.")
    return True


def flush_device(device):
    """Solicita ao kernel e ao dispositivo USB a descarga dos buffers de escrita."""
    result = subprocess.run(
        ["sudo", "blockdev", "--flushbufs", device],
        text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        fail(
            "Não consegui descarregar os buffers do cartão: "
            + (result.stderr.strip() or "erro desconhecido")
        )


def set_device_read_only(device):
    """Impede novas escritas no dispositivo enquanto a gravação é validada."""
    result = subprocess.run(
        ["sudo", "blockdev", "--setro", device],
        text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        print(
            f"AVISO: não consegui bloquear {device} contra novas escritas: "
            f"{result.stderr.strip() or 'erro desconhecido'}",
            file=sys.stderr,
        )
        return False
    return True


def power_off_device(device):
    """Desliga o leitor/cartão para evitar alterações depois da validação."""
    udisksctl = shutil.which("udisksctl")
    if udisksctl:
        result = subprocess.run(
            ["sudo", udisksctl, "power-off", "-b", device],
            text=True, capture_output=True, check=False
        )
        if result.returncode == 0:
            print("Cartão desligado com segurança; ele já pode ser retirado.")
            return True
        detail = result.stderr.strip()
    else:
        detail = "udisksctl não está instalado"

    eject = shutil.which("eject")
    if eject:
        result = subprocess.run(
            ["sudo", eject, "-s", device],
            text=True, capture_output=True, check=False
        )
        if result.returncode == 0:
            print("Cartão ejetado com segurança; ele já pode ser retirado.")
            return True
        detail = result.stderr.strip() or detail

    print(
        f"AVISO: não consegui desligar o dispositivo automaticamente ({detail}). "
        "Não o reinsira no Windows antes de confirmar a validação.",
        file=sys.stderr,
    )
    return False


def format_duration(seconds):
    seconds = max(0, int(seconds))
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours:
        return f"{hours:d}:{minutes:02d}:{seconds:02d}"
    return f"{minutes:02d}:{seconds:02d}"


def show_progress(label, completed, total, started, last_update, force=False, complete=False):
    now = time.monotonic()
    if not force and now - last_update < 0.5:
        return last_update
    elapsed = max(now - started, 0.001)
    ratio = min(completed / total, 1.0) if total else 1.0
    percent = ratio * 100
    if not complete:
        percent = min(percent, 99.9)
    filled = int(percent // 4)
    bar = "#" * filled + "-" * (25 - filled)
    speed = completed / elapsed
    remaining = (total - completed) / speed if speed > 0 else 0
    print(
        f"\r{label}: [{bar}] {percent:5.1f}%  "
        f"{fmt_size(completed)} / {fmt_size(total)}  "
        f"{fmt_size(speed)}/s  restante {format_duration(remaining)}",
        end="",
        flush=True,
    )
    return now


def read_partition_table(path):
    """Lê os limites das partições em setores usando sfdisk."""
    result = subprocess.run(
        ["sudo", "sfdisk", "--json", str(path)],
        text=True, capture_output=True, check=False
    )
    if result.returncode != 0:
        return None
    try:
        table = json.loads(result.stdout).get("partitiontable", {})
        if table.get("unit") != "sectors":
            return None
        partitions = []
        for number, item in enumerate(table.get("partitions", []), 1):
            if "start" not in item or "size" not in item:
                return None
            partitions.append({
                "number": number,
                "start": int(item["start"]),
                "size": int(item["size"]),
            })
        return partitions or None
    except (ValueError, TypeError, json.JSONDecodeError):
        return None


def update_partition_hashes(digests, partitions, chunk, chunk_start):
    """Distribui um bloco lido entre os hashes das partições correspondentes."""
    if not partitions:
        return
    chunk_end = chunk_start + len(chunk)
    for index, partition in enumerate(partitions):
        partition_start = partition["start"] * 512
        partition_end = partition_start + partition["size"] * 512
        overlap_start = max(chunk_start, partition_start)
        overlap_end = min(chunk_end, partition_end)
        if overlap_start < overlap_end:
            start = overlap_start - chunk_start
            end = overlap_end - chunk_start
            digests[index].update(chunk[start:end])


def partition_hash_values(digests):
    return [digest.hexdigest() for digest in digests]


def compare_partition_layouts(source, target):
    if len(source) != len(target):
        fail(
            "A quantidade de partições do cartão não corresponde à imagem: "
            f"{len(source)} contra {len(target)}."
        )
    for source_partition, target_partition in zip(source, target):
        if (
            source_partition["start"] != target_partition["start"]
            or source_partition["size"] != target_partition["size"]
        ):
            fail(
                "Os limites da partição "
                f"p{source_partition['number']} não correspondem à imagem."
            )


def print_partition_hashes(partitions, source_hashes, target_hashes):
    print("\nSHA-256 por partição:")
    mismatches = []
    for partition, source_hash, target_hash in zip(partitions, source_hashes, target_hashes):
        print(
            f"  p{partition['number']}: "
            f"imagem={source_hash}  cartão={target_hash}"
        )
        if source_hash != target_hash:
            mismatches.append(f"p{partition['number']}")
    if mismatches:
        fail("Hash divergente nas partições: " + ", ".join(mismatches) + ".")


def sha256_file(path, partitions=None):
    digest = hashlib.sha256()
    partition_digests = [hashlib.sha256() for _ in partitions] if partitions else []
    total = path.stat().st_size
    completed = 0
    started = time.monotonic()
    last_update = 0.0
    with open(path, "rb") as source:
        while True:
            chunk = source.read(4 * 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            update_partition_hashes(partition_digests, partitions, chunk, completed)
            completed += len(chunk)
            last_update = show_progress("Hash da imagem", completed, total, started, last_update)
    show_progress("Hash da imagem", completed, total, started, last_update, force=True, complete=True)
    print()
    return digest.hexdigest(), partition_hash_values(partition_digests)


def write_image(image_path, device):
    result = subprocess.run(
        ["sudo", "dd", f"if={image_path}", f"of={device}", "bs=4M", "status=progress", "conv=fsync"],
        check=False
    )
    if result.returncode != 0:
        fail("O dd encontrou um erro ao gravar no cartão.")


def sha256_device(device, size, partitions=None):
    command = [
        "sudo", "dd", f"if={device}", "bs=4M", "iflag=count_bytes",
        f"count={size}", "status=none"
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE)
    digest = hashlib.sha256()
    partition_digests = [hashlib.sha256() for _ in partitions] if partitions else []
    completed = 0
    started = time.monotonic()
    last_update = 0.0
    try:
        while True:
            chunk = process.stdout.read(4 * 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            update_partition_hashes(partition_digests, partitions, chunk, completed)
            completed += len(chunk)
            last_update = show_progress(
                "Verificação do cartão", completed, size, started, last_update
            )
    finally:
        process.stdout.close()
    result = process.wait()
    show_progress(
        "Verificação do cartão", completed, size, started, last_update,
        force=True, complete=(result == 0 and completed == size)
    )
    print()
    if result != 0:
        fail("Não consegui ler os dados gravados no cartão.")
    if completed != size:
        fail(f"A leitura do cartão terminou incompleta: {completed} de {size} bytes.")
    return digest.hexdigest(), partition_hash_values(partition_digests)


def main():
    for command in ("sudo", "lsblk", "blockdev", "dd", "umount", "sync", "udevadm", "sfdisk"):
        if shutil.which(command) is None:
            fail(f"Comando obrigatório não encontrado: {command}")

    if not os.path.ismount("/media/p3"):
        fail("/media/p3 não está montado.")
    if not IMAGE_DIR.is_dir():
        fail(f"A pasta de imagens não foi encontrada: {IMAGE_DIR}")

    print("=== Gravar imagem local no cartão SD via USB ===")
    print(f"Vou procurar imagens e arquivos .7z/.zip em: {IMAGE_DIR}")
    print("A gravação apaga todo o conteúdo do dispositivo USB escolhido.\n")

    subprocess.run(["sudo", "-v"], check=True)
    sources = scan_local_sources()
    if not sources:
        fail("Não encontrei .img, .iso, .raw, .wic, .7z ou .zip nessa pasta ou nas subpastas.")

    print("Arquivos encontrados:")
    selected = ask_choice(sources, "\nEscolha o arquivo da imagem: ")
    source_path = selected["source_path"]
    suffix = selected["suffix"]
    seven_zip = None

    with tempfile.TemporaryDirectory(prefix=".gravar-imagem-", dir=IMAGE_DIR) as temp_dir:
        if suffix in ARCHIVE_EXTENSIONS:
            if suffix == ".7z":
                seven_zip = seven_zip_command()
                if not seven_zip:
                    fail("O comando 7z não foi encontrado no Odroid.")
                found_images = seven_zip_images(seven_zip, source_path)
            else:
                found_images = zip_images(source_path)
            if not found_images:
                fail("O arquivo compactado não contém imagens .img, .iso, .raw ou .wic.")
            print("\nImagens encontradas dentro do arquivo:")
            selected_image = ask_choice(found_images, "\nEscolha a imagem para gravar: ")
            image_path = extract_image(source_path, suffix, selected_image, temp_dir, seven_zip)
            source_to_remove = source_path
        else:
            image_path = source_path
            source_to_remove = source_path

        image_size = image_path.stat().st_size
        if image_size == 0:
            fail("O arquivo de imagem está vazio.")

        devices = device_list()
        if not devices:
            fail("Nenhum disco USB/removível foi encontrado. A imagem de origem foi mantida.")
        print("\nDispositivos USB/removíveis encontrados:")
        for index, item in enumerate(devices, 1):
            print(f"  {index}) {item['name']} — {fmt_size(item['size'])} — {item['model']}")

        answer = input("\nDigite o número do cartão que receberá a imagem: ").strip()
        if not answer.isdigit() or not 1 <= int(answer) <= len(devices):
            fail("Escolha de dispositivo inválida.")
        device = devices[int(answer) - 1]["name"]

        nodes = list(walk_nodes(block_tree(device)))
        source_dir = str(IMAGE_DIR.resolve())
        for node in nodes:
            mount = node.get("mountpoint")
            if not mount:
                continue
            if mount == "/":
                fail("O dispositivo escolhido contém o sistema de arquivos raiz (/); gravação cancelada.")
            try:
                if os.path.commonpath([source_dir, mount]) == mount:
                    fail("A pasta ImagemMetcore está no dispositivo escolhido. Selecione o cartão USB correto.")
            except ValueError:
                pass

        print("\nDispositivo selecionado e partições atuais:")
        subprocess.run(["lsblk", "-o", "NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT", device], check=False)

        capacity = subprocess.run(
            ["sudo", "blockdev", "--getsize64", device],
            text=True, capture_output=True, check=False
        )
        if capacity.returncode != 0:
            fail("Não consegui ler a capacidade do cartão.")
        device_size = int(capacity.stdout.strip())
        print(f"\nTamanho da imagem: {image_size} bytes")
        print(f"Capacidade do cartão: {device_size} bytes")
        if image_size > device_size:
            fail(f"A imagem é maior que o cartão. A origem foi mantida em {source_path}.")
        if image_size < device_size:
            print(
                "AVISO: a imagem é menor que o dispositivo. A validação compara "
                "somente os bytes pertencentes à imagem, não o cartão inteiro."
            )

        source_partitions = read_partition_table(image_path)
        if source_partitions:
            print(f"Partições encontradas na imagem: {len(source_partitions)}")
        else:
            print("AVISO: não consegui ler a tabela de partições; será validado somente o hash geral.")

        image_hash, image_partition_hashes = sha256_file(image_path, source_partitions)
        print(f"SHA-256 da imagem: {image_hash}")
        print(f"\nO conteúdo de {device} será apagado e substituído pela imagem.")

        write_started = False
        udevadm = None
        try:
            # O bloqueio precisa ocorrer antes da desmontagem e do dd. Caso
            # contrário, o ambiente gráfico pode remontar uma partição durante
            # a gravação e alterar a imagem de forma intermitente.
            udevadm = stop_automount()
            unmount_device(device, settle=False)

            print(f"\nGravando em {device}. O dd mostrará os bytes gravados e a velocidade...")
            write_started = True
            write_image(image_path, device)
            subprocess.run(["sudo", "sync"], check=True)
            flush_device(device)

            # Depois que o dd recria a tabela de partições, o ambiente gráfico
            # não pode montar o cartão porque a fila udev está bloqueada. Ainda
            # assim, desmontamos qualquer partição que já estivesse montada.
            unmount_device(device, settle=False)
            set_device_read_only(device)

            target_partitions = read_partition_table(device)
            if source_partitions:
                if not target_partitions:
                    fail("Não consegui ler a tabela de partições do cartão gravado.")
                compare_partition_layouts(source_partitions, target_partitions)

            print("\nLendo os dados gravados para conferir o SHA-256...")
            readback_hash, readback_partition_hashes = sha256_device(
                device, image_size, source_partitions
            )
            print(f"SHA-256 no cartão: {readback_hash}")
            if source_partitions:
                print_partition_hashes(
                    source_partitions,
                    image_partition_hashes,
                    readback_partition_hashes,
                )
            if readback_hash != image_hash:
                fail(f"O hash do cartão não corresponde. A origem foi mantida em {source_path}.")
        finally:
            try:
                if write_started:
                    # Mesmo em caso de erro, não deixe o cartão montado ou
                    # acessível para novas escritas automáticas.
                    unmount_device(device, fail_on_error=False, settle=False)
                    set_device_read_only(device)
                    subprocess.run(["sudo", "sync"], check=False)
                    flush_result = subprocess.run(
                        ["sudo", "blockdev", "--flushbufs", device],
                        text=True, capture_output=True, check=False
                    )
                    if flush_result.returncode != 0:
                        print(
                            "AVISO: não consegui descarregar os buffers durante a limpeza: "
                            + (flush_result.stderr.strip() or "erro desconhecido"),
                            file=sys.stderr,
                        )
                    power_off_device(device)
            finally:
                # Nunca deixe a fila udev bloqueada, mesmo se a gravação ou a
                # limpeza terminar com erro.
                if udevadm:
                    start_automount(udevadm)

        print("\nSUCESSO: gravação verificada.")
        remove_source = input(
            f"Deseja excluir o arquivo escolhido em ImagemMetcore ({source_to_remove.name})? (s/N): "
        ).strip().lower()
        if remove_source in ("s", "sim"):
            source_to_remove.unlink()
            print(f"Arquivo de origem excluído: {source_to_remove}")
        else:
            print(f"Arquivo de origem mantido: {source_to_remove}")

        script_name = SCRIPT_PATH.name if SCRIPT_PATH else "gravar-imagem-sd.sh"
        remove_script = input(f"Deseja excluir este script ({script_name})? (s/N): ").strip().lower()
        if remove_script in ("s", "sim") and SCRIPT_PATH and SCRIPT_PATH.is_file():
            SCRIPT_PATH.unlink()
            print(f"Script excluído: {SCRIPT_PATH}")
        else:
            print("Script mantido.")
        print("O cartão foi finalizado e desligado com segurança.")


try:
    main()
except KeyboardInterrupt:
    print("\nOperação interrompida. Se a gravação já começou, mantenha o cartão conectado.")
    raise SystemExit(130)
except (OSError, zipfile.BadZipFile, json.JSONDecodeError, subprocess.CalledProcessError) as error:
    print(f"\nERRO: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
python3 "$script_tmp" "$0" "$@"

