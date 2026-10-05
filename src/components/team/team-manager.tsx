"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Loader2, MapPin, Plus, UserPlus, Users, Factory as FactoryIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { RegionTagsInput } from "./region-tags-input";
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
import { createStaffAccountAction, createRegionAction } from "@/lib/actions/admin";
import { createStaffAccountSchema, regionNameSchema } from "@/lib/domain/validators";
import { ToggleActiveButton, ResetPasswordButton, DeleteStaffButton } from "./staff-actions";
import { EditDriverButton } from "./edit-driver-dialog";
import { ManagerFactoriesButton } from "./manager-factories-dialog";
import { FactoriesMapPanel } from "./factories-map-panel";
import { AddFactoryPanel } from "./add-factory-panel";
import type { Profile, Region, UserRole, Factory } from "@/types/database";

const ROLE_LABELS_AR: Record<UserRole, string> = {
  owner: "مدير",
  moderator: "موديريتور",
  driver: "مندوب",
  factory: "المصنع",
};

const ROLE_OPTIONS: UserRole[] = ["moderator", "driver", "owner"];

export function TeamManager({
  staff,
  factories,
  regions,
  driverRegionsMap,
  managerFactoriesMap,
  viewerRole,
}: {
  staff: Profile[];
  factories: Factory[];
  regions: Region[];
  driverRegionsMap: Record<string, string[]>;
  managerFactoriesMap: Record<string, string[]>;
  viewerRole: UserRole;
}) {
  const [staffList, setStaffList] = useState(staff);

  const [regionsList, setRegionsList] = useState(regions);
  const [prevRegions, setPrevRegions] = useState(regions);
  if (regions !== prevRegions) {
    setPrevRegions(regions);
    setRegionsList(regions);
  }

  const [regionsByDriver, setRegionsByDriver] = useState(driverRegionsMap);
  const [prevDriverRegionsMap, setPrevDriverRegionsMap] = useState(driverRegionsMap);
  if (driverRegionsMap !== prevDriverRegionsMap) {
    setPrevDriverRegionsMap(driverRegionsMap);
    setRegionsByDriver(driverRegionsMap);
  }

  const [factoriesByManager, setFactoriesByManager] = useState(managerFactoriesMap);
  const [prevManagerFactoriesMap, setPrevManagerFactoriesMap] = useState(managerFactoriesMap);
  if (managerFactoriesMap !== prevManagerFactoriesMap) {
    setPrevManagerFactoriesMap(managerFactoriesMap);
    setFactoriesByManager(managerFactoriesMap);
  }

  const isModerator = viewerRole === "moderator";

  const workers = useMemo(() => staffList.filter((m) => m.role !== "factory"), [staffList]);

  const [factoryList, setFactoryList] = useState(factories);
  const [prevFactories, setPrevFactories] = useState(factories);
  if (factories !== prevFactories) {
    setPrevFactories(factories);
    setFactoryList(factories);
  }

  function updateFactory(id: string, patch: Partial<Factory>) {
    setFactoryList((prev) => prev.map((f) => (f.id === id ? { ...f, ...patch } : f)));
  }

  function updateMember(id: string, patch: Partial<Profile>) {
    setStaffList((prev) => prev.map((m) => (m.id === id ? { ...m, ...patch } : m)));
  }

  function toggleActive(id: string, isActive: boolean) {
    updateMember(id, { is_active: isActive });
  }

  function removeMember(id: string) {
    setStaffList((prev) => prev.filter((m) => m.id !== id));
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
            <FactoryIcon className="size-4" />
            المصانع ({factoryList.length})
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
                      <TableHead>التغطية</TableHead>
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
                              regions={regionsList}
                              assignedIds={regionsByDriver[member.id] ?? []}
                            />
                          ) : (
                            <ManagerFactoriesCell
                              factories={factoryList}
                              assignedIds={factoriesByManager[member.id] ?? []}
                            />
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
                              {!isModerator && member.role !== "driver" && (
                                <ManagerFactoriesButton
                                  managerId={member.id}
                                  managerName={member.full_name}
                                  factories={factoryList}
                                  assignedIds={factoriesByManager[member.id] ?? []}
                                  onSaved={(ids) =>
                                    setFactoriesByManager((prev) => ({ ...prev, [member.id]: ids }))
                                  }
                                />
                              )}
                              {!isModerator && member.role === "driver" && (
                                <EditDriverButton
                                  driverId={member.id}
                                  fullName={member.full_name}
                                  phone={member.phone}
                                  regions={regionsList}
                                  assignedRegionNames={regionsList
                                    .filter((r) => (regionsByDriver[member.id] ?? []).includes(r.id))
                                    .map((r) => r.name)}
                                  onSaved={(fullName) => updateMember(member.id, { full_name: fullName })}
                                />
                              )}
                              <ToggleActiveButton
                                userId={member.id}
                                isActive={member.is_active}
                                onToggled={(isActive) => toggleActive(member.id, isActive)}
                              />
                              <ResetPasswordButton userId={member.id} />
                              {!isModerator && member.role !== "owner" && (
                                <DeleteStaffButton
                                  userId={member.id}
                                  fullName={member.full_name}
                                  isDriver={member.role === "driver"}
                                  onDeleted={() => removeMember(member.id)}
                                />
                              )}
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
            factories={factoryList}
            onSaved={(id, next) => updateFactory(id, next)}
            onToggled={(id, isActive) => updateFactory(id, { is_active: isActive })}
            onDeleted={(id) => setFactoryList((prev) => prev.filter((f) => f.id !== id))}
            canDelete={!isModerator}
          />
        </TabsContent>

        {!isModerator && (
          <TabsContent value="add-factory">
            <AddFactoryPanel
              onCreated={(factory) => {
                setFactoryList((prev) => [factory, ...prev]);
                setActiveTab("factories");
              }}
            />
          </TabsContent>
        )}
      </Tabs>
    </div>
  );
}

function DriverRegionsCell({ regions, assignedIds }: { regions: Region[]; assignedIds: string[] }) {
  const assignedNames = regions.filter((r) => assignedIds.includes(r.id)).map((r) => r.name);

  return (
    <span className="flex items-center gap-1 text-sm">
      <MapPin className="size-3.5 shrink-0 text-muted-foreground" />
      {assignedNames.length > 0 ? (
        assignedNames.join("، ")
      ) : (
        <span className="text-muted-foreground">لا توجد مناطق</span>
      )}
    </span>
  );
}

function ManagerFactoriesCell({ factories, assignedIds }: { factories: Factory[]; assignedIds: string[] }) {
  const assignedNames = factories.filter((f) => assignedIds.includes(f.id)).map((f) => f.name);

  return (
    <span className="flex items-center gap-1 text-sm">
      <FactoryIcon className="size-3.5 shrink-0 text-muted-foreground" />
      {assignedNames.length > 0 ? (
        assignedNames.join("، ")
      ) : (
        <span className="text-muted-foreground">لا توجد مصانع</span>
      )}
    </span>
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
  const roleOptions = ROLE_OPTIONS;
  const [open, setOpen] = useState(false);
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<UserRole>(roleOptions[0]);
  const [regionNames, setRegionNames] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const router = useRouter();

  function reset() {
    setFullName("");
    setPhone("");
    setEmail("");
    setRole(roleOptions[0]);
    setRegionNames([]);
    setError(null);
  }

  function submit() {
    const parsed = createStaffAccountSchema.safeParse({
      full_name: fullName,
      phone,
      email: email || undefined,
      role,
      region_names: role === "driver" ? regionNames : [],
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
      if (parsed.data.region_names.length > 0) router.refresh();
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
              <RegionTagsInput value={regionNames} onChange={setRegionNames} regions={regions} />
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
