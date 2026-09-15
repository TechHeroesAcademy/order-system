"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, MapPin, Plus, UserPlus, Users, KeyRound, Factory } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { EmptyState } from "@/components/shared/empty-state";
import {
  createStaffAccountAction,
  createRegionAction,
  setStaffActiveAction,
  setDriverRegionsAction,
  resetStaffPasswordAction,
  updateStaffAddressAction,
} from "@/lib/actions/admin";
import { createStaffAccountSchema, regionNameSchema, updateStaffAddressSchema } from "@/lib/domain/validators";
import type { Profile, Region, UserRole } from "@/types/database";

const ROLE_LABELS_AR: Record<UserRole, string> = {
  owner: "صاحب النظام",
  moderator: "موديريتور",
  driver: "مندوب",
  factory: "المصنع",
};

const ROLE_OPTIONS: UserRole[] = ["moderator", "driver", "factory", "owner"];

export function TeamManager({
  staff,
  regions,
  driverRegionsMap,
  viewerRole,
}: {
  staff: Profile[];
  regions: Region[];
  driverRegionsMap: Record<string, string[]>;
  /** Owner sees/can do everything; Moderator is scoped to driver/factory accounts. */
  viewerRole: UserRole;
}) {
  const [staffList, setStaffList] = useState(staff);
  const [regionsList, setRegionsList] = useState(regions);
  const [regionsByDriver, setRegionsByDriver] = useState(driverRegionsMap);
  const isModerator = viewerRole === "moderator";

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-bold">إدارة الفريق</h1>
        <div className="flex gap-2">
          {!isModerator && (
            <AddRegionDialog
              onCreated={(region) => setRegionsList((prev) => [...prev, region].sort((a, b) => a.name.localeCompare(b.name)))}
            />
          )}
          <AddStaffDialog
            regions={regionsList}
            viewerRole={viewerRole}
            onCreated={(profile) => setStaffList((prev) => [profile, ...prev])}
          />
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">أعضاء الفريق ({staffList.length})</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {staffList.length === 0 ? (
            <EmptyState icon={Users} title="لا يوجد أعضاء بعد" />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>الاسم</TableHead>
                  <TableHead>الهاتف</TableHead>
                  <TableHead>الدور</TableHead>
                  <TableHead>المناطق / الموقع</TableHead>
                  <TableHead>الحالة</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {staffList.map((member) => (
                  <TableRow key={member.id}>
                    <TableCell className="font-medium">{member.full_name}</TableCell>
                    <TableCell className="text-muted-foreground" dir="ltr">
                      {member.phone ?? "—"}
                    </TableCell>
                    <TableCell>
                      <Badge variant="outline">{ROLE_LABELS_AR[member.role]}</Badge>
                    </TableCell>
                    <TableCell>
                      {member.role === "driver" ? (
                        <DriverRegionsCell
                          driverId={member.id}
                          regions={regionsList}
                          assignedIds={regionsByDriver[member.id] ?? []}
                          onSaved={(ids) => setRegionsByDriver((prev) => ({ ...prev, [member.id]: ids }))}
                        />
                      ) : member.role === "factory" ? (
                        <FactoryAddressCell
                          factoryId={member.id}
                          address={member.address}
                          onSaved={(address) =>
                            setStaffList((prev) => prev.map((m) => (m.id === member.id ? { ...m, address } : m)))
                          }
                        />
                      ) : (
                        <span className="text-muted-foreground">—</span>
                      )}
                    </TableCell>
                    <TableCell>
                      {member.is_active ? (
                        <Badge variant="success">نشط</Badge>
                      ) : (
                        <Badge variant="destructive">موقوف</Badge>
                      )}
                    </TableCell>
                    <TableCell>
                      {isModerator && !["driver", "factory"].includes(member.role) ? (
                        <span className="text-xs text-muted-foreground">—</span>
                      ) : (
                        <div className="flex gap-2">
                          <ToggleActiveButton
                            userId={member.id}
                            isActive={member.is_active}
                            onToggled={(isActive) =>
                              setStaffList((prev) =>
                                prev.map((m) => (m.id === member.id ? { ...m, is_active: isActive } : m)),
                              )
                            }
                          />
                          <ResetPasswordButton userId={member.id} />
                        </div>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

function ToggleActiveButton({
  userId,
  isActive,
  onToggled,
}: {
  userId: string;
  isActive: boolean;
  onToggled: (isActive: boolean) => void;
}) {
  const [pending, startTransition] = useTransition();

  function toggle() {
    startTransition(async () => {
      const res = await setStaffActiveAction(userId, !isActive);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      onToggled(!isActive);
      toast.success(!isActive ? "تم تفعيل الحساب" : "تم إيقاف الحساب");
    });
  }

  return (
    <Button size="sm" variant={isActive ? "outline" : "default"} onClick={toggle} disabled={pending}>
      {pending && <Loader2 className="animate-spin" />}
      {isActive ? "إيقاف" : "تفعيل"}
    </Button>
  );
}

/**
 * Invalidates the old password immediately and flips the account back to
 * "needs to set a password" — the worker just signs in with their phone
 * number as usual and is prompted to create a new one, no temp password to
 * relay over the phone.
 */
function ResetPasswordButton({ userId }: { userId: string }) {
  const [pending, startTransition] = useTransition();

  function reset() {
    startTransition(async () => {
      const res = await resetStaffPasswordAction(userId);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم إعادة تعيين كلمة المرور — سيقوم بإنشاء كلمة مرور جديدة عند تسجيل الدخول برقم هاتفه");
    });
  }

  return (
    <Button size="sm" variant="outline" onClick={reset} disabled={pending} title="إعادة تعيين كلمة المرور">
      {pending ? <Loader2 className="animate-spin" /> : <KeyRound className="size-4" />}
    </Button>
  );
}

function DriverRegionsCell({
  driverId,
  regions,
  assignedIds,
  onSaved,
}: {
  driverId: string;
  regions: Region[];
  assignedIds: string[];
  onSaved: (ids: string[]) => void;
}) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string[]>(assignedIds);
  const [pending, startTransition] = useTransition();

  const assignedNames = regions.filter((r) => assignedIds.includes(r.id)).map((r) => r.name);

  function toggleRegion(id: string, checked: boolean) {
    setSelected((prev) => (checked ? [...prev, id] : prev.filter((r) => r !== id)));
  }

  function save() {
    startTransition(async () => {
      const res = await setDriverRegionsAction(driverId, selected);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      onSaved(selected);
      toast.success("تم تحديث مناطق المندوب");
      setOpen(false);
    });
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) setSelected(assignedIds);
      }}
    >
      <DialogTrigger asChild>
        <button className="flex items-center gap-1 text-start text-sm hover:underline">
          <MapPin className="size-3.5 text-muted-foreground" />
          {assignedNames.length > 0 ? assignedNames.join("، ") : "تحديد المناطق"}
        </button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>مناطق تغطية المندوب</DialogTitle>
          <DialogDescription>حدد المناطق التي يغطيها هذا المندوب لترشيحه تلقائيًا لأوردراتها.</DialogDescription>
        </DialogHeader>
        <div className="max-h-64 space-y-2 overflow-y-auto">
          {regions.length === 0 && <p className="text-sm text-muted-foreground">لا يوجد مناطق مضافة بعد.</p>}
          {regions.length > 0 && (
            <label className="flex items-center gap-2 border-b pb-2 text-sm font-medium">
              <Checkbox
                checked={selected.length === regions.length}
                onCheckedChange={(checked) => setSelected(checked === true ? regions.map((r) => r.id) : [])}
              />
              تحديد الكل
            </label>
          )}
          {regions.map((r) => (
            <label key={r.id} className="flex items-center gap-2 text-sm">
              <Checkbox
                checked={selected.includes(r.id)}
                onCheckedChange={(checked) => toggleRegion(r.id, checked === true)}
              />
              {r.name}
            </label>
          ))}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button onClick={save} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            حفظ
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function FactoryAddressCell({
  factoryId,
  address,
  onSaved,
}: {
  factoryId: string;
  address: string | null;
  onSaved: (address: string | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [value, setValue] = useState(address ?? "");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function save() {
    const parsed = updateStaffAddressSchema.safeParse({ address: value });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await updateStaffAddressAction(factoryId, parsed.data);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      onSaved(parsed.data.address?.trim() || null);
      toast.success("تم تحديث عنوان المصنع");
      setOpen(false);
    });
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) setValue(address ?? "");
      }}
    >
      <DialogTrigger asChild>
        <button className="flex items-center gap-1 text-start text-sm hover:underline">
          <Factory className="size-3.5 text-muted-foreground" />
          {address || "تحديد الموقع"}
        </button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>موقع المصنع</DialogTitle>
          <DialogDescription>
            يظهر هذا العنوان للمندوب عند تسليم أو استلام أوردر مرتبط بهذا المصنع.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-1.5">
          <Label htmlFor={`factory-address-${factoryId}`}>العنوان</Label>
          <Input
            id={`factory-address-${factoryId}`}
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder="مثال: المنطقة الصناعية، مدينة نصر، مبنى 12"
          />
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button onClick={save} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            حفظ
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function AddRegionDialog({ onCreated }: { onCreated: (region: Region) => void }) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    const parsed = regionNameSchema.safeParse({ name });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "اسم غير صالح");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await createRegionAction(parsed.data);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      onCreated({ id: res.data.id, name: parsed.data.name, created_at: new Date().toISOString() });
      toast.success("تمت إضافة المنطقة");
      setName("");
      setOpen(false);
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline">
          <Plus />
          منطقة جديدة
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إضافة منطقة</DialogTitle>
          <DialogDescription>المناطق تُستخدم لتوزيع الأوردرات وترشيح المندوبين.</DialogDescription>
        </DialogHeader>
        <div className="space-y-1.5">
          <Label htmlFor="region-name">اسم المنطقة</Label>
          <Input id="region-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="مثال: مدينة نصر" />
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button onClick={submit} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            إضافة
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function AddStaffDialog({
  regions,
  viewerRole,
  onCreated,
}: {
  regions: Region[];
  viewerRole: UserRole;
  onCreated: (profile: Profile) => void;
}) {
  const roleOptions = viewerRole === "moderator" ? (["driver", "factory"] as const) : ROLE_OPTIONS;
  const [open, setOpen] = useState(false);
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<UserRole>(roleOptions[0]);
  const [regionIds, setRegionIds] = useState<string[]>([]);
  const [address, setAddress] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function reset() {
    setFullName("");
    setPhone("");
    setEmail("");
    setRole(roleOptions[0]);
    setRegionIds([]);
    setAddress("");
    setError(null);
  }

  function toggleRegion(id: string, checked: boolean) {
    setRegionIds((prev) => (checked ? [...prev, id] : prev.filter((r) => r !== id)));
  }

  function submit() {
    const parsed = createStaffAccountSchema.safeParse({
      full_name: fullName,
      phone,
      email: email || undefined,
      role,
      region_ids: role === "driver" ? regionIds : [],
      address: role === "factory" ? address : undefined,
    });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await createStaffAccountAction(parsed.data);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      onCreated({
        id: res.data.userId,
        full_name: parsed.data.full_name,
        phone: parsed.data.phone,
        role: parsed.data.role,
        region_id: null,
        address: parsed.data.role === "factory" ? (parsed.data.address?.trim() || null) : null,
        is_active: true,
        password_set: false,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });
      toast.success("تم إنشاء الحساب — يمكنه تسجيل الدخول برقم هاتفه وإنشاء كلمة مرور لأول مرة");
      reset();
      setOpen(false);
    });
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (!next) reset();
      }}
    >
      <DialogTrigger asChild>
        <Button>
          <UserPlus />
          عضو جديد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إضافة عضو فريق</DialogTitle>
          <DialogDescription>يسجل دخوله برقم هاتفه، وينشئ كلمة مرور بنفسه أول مرة يدخل بها.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="staff-name">الاسم</Label>
            <Input id="staff-name" value={fullName} onChange={(e) => setFullName(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="staff-phone">رقم الهاتف</Label>
            <Input id="staff-phone" dir="ltr" placeholder="01xxxxxxxxx" value={phone} onChange={(e) => setPhone(e.target.value)} />
            <p className="text-xs text-muted-foreground">هذا هو رقم تسجيل الدخول — لازم يكون صحيحًا.</p>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="staff-email">البريد الإلكتروني (اختياري)</Label>
            <Input id="staff-email" type="email" dir="ltr" value={email} onChange={(e) => setEmail(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label>الدور</Label>
            <Select value={role} onValueChange={(v) => setRole(v as UserRole)}>
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {roleOptions.map((r) => (
                  <SelectItem key={r} value={r}>
                    {ROLE_LABELS_AR[r]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          {role === "factory" && (
            <div className="space-y-1.5">
              <Label htmlFor="staff-address">عنوان المصنع (اختياري)</Label>
              <Input
                id="staff-address"
                value={address}
                onChange={(e) => setAddress(e.target.value)}
                placeholder="مثال: المنطقة الصناعية، مدينة نصر، مبنى 12"
              />
              <p className="text-xs text-muted-foreground">يظهر هذا العنوان للمندوب عند تسليم أو استلام أوردر من هذا المصنع.</p>
            </div>
          )}
          {role === "driver" && (
            <div className="space-y-1.5">
              <Label>المناطق التي يغطيها</Label>
              <div className="max-h-40 space-y-2 overflow-y-auto rounded-md border p-2">
                {regions.length === 0 && <p className="text-sm text-muted-foreground">لا يوجد مناطق مضافة بعد.</p>}
                {regions.length > 0 && (
                  <label className="flex items-center gap-2 border-b pb-2 text-sm font-medium">
                    <Checkbox
                      checked={regionIds.length === regions.length}
                      onCheckedChange={(checked) => setRegionIds(checked === true ? regions.map((r) => r.id) : [])}
                    />
                    تحديد الكل
                  </label>
                )}
                {regions.map((r) => (
                  <label key={r.id} className="flex items-center gap-2 text-sm">
                    <Checkbox
                      checked={regionIds.includes(r.id)}
                      onCheckedChange={(checked) => toggleRegion(r.id, checked === true)}
                    />
                    {r.name}
                  </label>
                ))}
              </div>
            </div>
          )}
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button onClick={submit} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            إنشاء الحساب
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
