"use client";

import { useMemo, useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, MapPin, Plus, UserPlus, Users, Factory } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
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
  setDriverRegionsAction,
} from "@/lib/actions/admin";
import { createStaffAccountSchema, regionNameSchema } from "@/lib/domain/validators";
import { ToggleActiveButton, ResetPasswordButton } from "./staff-actions";
import { FactoriesMapPanel } from "./factories-map-panel";
import { AddFactoryPanel } from "./add-factory-panel";
import type { Profile, Region, UserRole } from "@/types/database";

const ROLE_LABELS_AR: Record<UserRole, string> = {
  owner: "مدير",
  moderator: "موديريتور",
  driver: "مندوب",
  factory: "المصنع",
};

// Factory accounts have their own dedicated "إضافة مصنع" tab now (see
// AddFactoryPanel) — the shared "عضو جديد" dialog below only ever creates
// driver/moderator/owner ("another manager") accounts.
const ROLE_OPTIONS: UserRole[] = ["moderator", "driver", "owner"];

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

  const workers = useMemo(() => staffList.filter((m) => m.role !== "factory"), [staffList]);
  const factories = useMemo(() => staffList.filter((m) => m.role === "factory"), [staffList]);

  function updateMember(id: string, patch: Partial<Profile>) {
    setStaffList((prev) => prev.map((m) => (m.id === id ? { ...m, ...patch } : m)));
  }

  function toggleActive(id: string, isActive: boolean) {
    updateMember(id, { is_active: isActive });
  }

  const [activeTab, setActiveTab] = useState("workers");

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
          {/* Adding a new worker or factory account is Manager-only now (see
              migration 0024 / createStaffAccountAction) — a Moderator no
              longer gets this control at all, not even scoped to drivers. */}
          {!isModerator && (
            <AddStaffDialog
              regions={regionsList}
              onCreated={(profile) => setStaffList((prev) => [profile, ...prev])}
            />
          )}
        </div>
      </div>

      <Tabs value={activeTab} onValueChange={setActiveTab}>
        <TabsList>
          <TabsTrigger value="workers">
            <Users className="size-4" />
            الموظفون ({workers.length})
          </TabsTrigger>
          <TabsTrigger value="factories">
            <Factory className="size-4" />
            المصانع ({factories.length})
          </TabsTrigger>
          {!isModerator && (
            <TabsTrigger value="add-factory">
              <Plus className="size-4" />
              إضافة مصنع
            </TabsTrigger>
          )}
        </TabsList>

        <TabsContent value="workers" className="space-y-4">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">الموظفون ({workers.length})</CardTitle>
            </CardHeader>
            <CardContent className="p-0">
              {workers.length === 0 ? (
                <EmptyState icon={Users} title="لا يوجد موظفون بعد" />
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>الاسم</TableHead>
                      <TableHead>الهاتف</TableHead>
                      <TableHead>الدور</TableHead>
                      <TableHead>المناطق</TableHead>
                      <TableHead>الحالة</TableHead>
                      <TableHead />
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {workers.map((member) => (
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
                                onToggled={(isActive) => toggleActive(member.id, isActive)}
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
        </TabsContent>

        <TabsContent value="factories">
          <FactoriesMapPanel
            factories={factories}
            onSaved={(id, next) => updateMember(id, next)}
            onToggled={(id, isActive) => toggleActive(id, isActive)}
          />
        </TabsContent>

        {!isModerator && (
          <TabsContent value="add-factory">
            <AddFactoryPanel
              onCreated={(profile) => {
                setStaffList((prev) => [profile, ...prev]);
                setActiveTab("factories");
              }}
            />
          </TabsContent>
        )}
      </Tabs>
    </div>
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
  onCreated,
}: {
  regions: Region[];
  onCreated: (profile: Profile) => void;
}) {
  // This dialog is Owner-only now (see TeamManager — a Moderator never even
  // sees the trigger button), so every role in ROLE_OPTIONS is fair game;
  // factory accounts still have their own separate "إضافة مصنع" tab
  // (AddFactoryPanel) rather than being one more option here.
  const roleOptions = ROLE_OPTIONS;
  const [open, setOpen] = useState(false);
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<UserRole>(roleOptions[0]);
  const [regionIds, setRegionIds] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function reset() {
    setFullName("");
    setPhone("");
    setEmail("");
    setRole(roleOptions[0]);
    setRegionIds([]);
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
        // This dialog never creates a factory account anymore (see
        // AddFactoryPanel), so there's never an address/pin to set here.
        address: null,
        lat: null,
        lng: null,
        maps_url: null,
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
