# AWS Build Guide – Three-Tier Expense Tracker (AWS Academy Learner Lab)

Follow the steps in order. Every name in `code` is the name to type in the console, so the
later steps can find it. 📸 marks a screenshot to take for the report.

> **Recommended: the automated way.** In the AWS Academy Cloud Developing **Sandbox** (the one this
> project was deployed in), launching EC2 instances from your own saved AMIs is blocked. So the project is
> deployed with `scripts/deploy.sh`: each server installs the app **at boot** (launch-template user data)
> instead of using saved images, and private app servers fetch a prebuilt bundle from S3 through a free
> **S3 gateway endpoint**. Run `bash deploy.sh all` (about 25 minutes), `status`, `pause`, `resume`, `teardown`.
> The manual console steps below still explain every component; where they say "create image / AMI",
> the script uses Amazon Linux 2023 + user data instead.

---

## 0. Before you start

1. Open AWS Academy → **Learner Lab** → **Start Lab** → wait for the green dot → click **AWS**.
2. Top-right of the console: region must be **N. Virginia (us-east-1)**. Learner Lab only allows
   us-east-1 and us-west-2. Keep everything in us-east-1.
3. Do the whole build in **one** team member's Learner Lab account.
4. Download this repository (ZIP) to your laptop. You will upload two folders to S3 in step 3.
5. A lab session lasts at most 4 hours. Resources stay when it ends, but EC2 instances are stopped.
   Plan each work session around one or two sections below.

**Budget rules (the lab budget is about $100; if it runs out, the account and everything in it are lost):**

- Never create a **NAT gateway** – this design does not need one.
- Use only **t3.micro** (EC2) and **db.t3.micro** (RDS).
- At the end of every work day, do the **Pause** steps in section 9.
- Rough cost: about $3/day with everything running, about $1/day when paused. Check the budget
  shown on the Learner Lab page (it updates every 8–12 hours).

---

## 1. Network: VPC and 6 subnets

**VPC → Create VPC → "VPC and more"**

| Setting | Value |
|---|---|
| Name tag auto-generation | `expense` |
| IPv4 CIDR | `10.0.0.0/16` |
| Number of Availability Zones | `2` |
| Number of public subnets | `2` |
| Number of private subnets | `4` (if 4 is not offered, choose 2 and add 2 manually – see below) |
| NAT gateways | **None** |
| VPC endpoints | **None** |

Click **Create VPC**. 📸 the resource map.

**Rename the subnets** (VPC → Subnets → click the name to edit) so the tiers are clear:

| Subnet created by wizard | Rename to |
|---|---|
| public subnet in AZ a | `web-public-a` |
| public subnet in AZ b | `web-public-b` |
| first private subnet in AZ a | `app-private-a` |
| first private subnet in AZ b | `app-private-b` |
| second private subnet in AZ a | `db-private-a` |
| second private subnet in AZ b | `db-private-b` |

*If you only got 2 private subnets:* Subnets → Create subnet → VPC `expense-vpc`, create
`db-private-a` (AZ us-east-1a, CIDR e.g. `10.0.160.0/20`) and `db-private-b` (us-east-1b,
`10.0.176.0/20`). Use CIDRs that don't overlap the existing ones.

**Public subnets get public IPs:** select `web-public-a` → Actions → Edit subnet settings →
tick **Enable auto-assign public IPv4 address** → Save. Repeat for `web-public-b`.

---

## 2. Security groups (the "chain")

**EC2 → Security Groups → Create security group.** VPC = `expense-vpc` for all five.
Leave outbound rules as default (all traffic).

| Name | Inbound rule | Source |
|---|---|---|
| `web-alb-sg` | HTTP 80 | `0.0.0.0/0` (Anywhere-IPv4) |
| `web-sg` | HTTP 80 | security group `web-alb-sg` |
| `app-alb-sg` | HTTP 80 | security group `web-sg` |
| `app-sg` | Custom TCP 4000 | security group `app-alb-sg` |
| `db-sg` | MYSQL/Aurora 3306 | security group `app-sg` |

Create them top to bottom (each one references the one above). 📸 the list.

> Viva point: each tier accepts traffic **only** from the tier in front of it. Nobody on the
> internet can reach the app servers or the database directly.

---

## 3. S3 bucket with the code

1. **S3 → Create bucket** → name `expense-code-<your-roll-no>` (must be globally unique),
   region us-east-1, keep "Block all public access" ON → Create.
2. Open the bucket → **Upload → Add folder** → upload `app-tier`, `web-tier` and `scripts`
   from this repository. (Don't upload `node_modules` or any `.env` file.)

📸 the bucket contents.

---

## 4. Database tier: Amazon RDS (MySQL)

**4a. Subnet group** – RDS → Subnet groups → Create:
name `expense-db-subnets`, VPC `expense-vpc`, AZs us-east-1a and us-east-1b,
subnets `db-private-a` and `db-private-b`.

**4b. Database** – RDS → Create database → **Standard create**:

| Setting | Value |
|---|---|
| Engine | MySQL |
| Template | **Free tier** (or Dev/Test if Free tier isn't shown) |
| Availability | **Single-AZ** |
| DB instance identifier | `expense-db` |
| Master username | `admin` |
| Master password | choose one and share it only with your team |
| Instance class | **db.t3.micro** |
| Storage | gp2 or gp3, **20 GiB**, untick "Enable storage autoscaling" |
| VPC / subnet group | `expense-vpc` / `expense-db-subnets` |
| Public access | **No** |
| Security group | remove `default`, choose `db-sg` |
| Additional configuration → Initial database name | `expensedb` |
| Backups / Performance Insights / Enhanced monitoring | turn off (saves budget) |

Create. It takes about 5–10 minutes. Then open `expense-db` → copy the **Endpoint**. 📸 the
Connectivity tab showing "Publicly accessible: No".

---

## 5. App tier

**5a. Build instance** – EC2 → Launch instance:

| Setting | Value |
|---|---|
| Name | `app-build` |
| AMI | Amazon Linux 2023 |
| Instance type | t3.micro |
| Key pair | Proceed without a key pair |
| Network settings → Edit | VPC `expense-vpc`, subnet `web-public-a`, auto-assign public IP **Enable** |
| Security group | existing: `app-sg` |
| Advanced details → IAM instance profile | **LabInstanceProfile** |

(It sits in a public subnet only so it can download Node.js. No NAT gateway needed.)

Wait 2 minutes → select it → **Connect → Session Manager → Connect**. Run:

```bash
sudo -i
aws s3 cp s3://expense-code-<your-roll-no>/scripts/app-setup.sh .
bash app-setup.sh expense-code-<your-roll-no>
```

Enter the RDS endpoint, `admin`, your password and `expensedb` when asked.
The last line must show `"database":"reachable"`. 📸 this output.

**5b. Save it as an image** – select `app-build` → Actions → Image and templates →
Create image → name `app-tier-ami` → Create. Wait until AMIs shows **Available**.

**5c. Target group** – EC2 → Target groups → Create:
type Instances, name `app-tg`, protocol HTTP, port **4000**, VPC `expense-vpc`,
health check path `/health`. Don't register any targets → Create.

**5d. Internal load balancer** – EC2 → Load balancers → Create → **Application Load Balancer**:
name `app-alb`, scheme **Internal**, VPC `expense-vpc`, subnets `app-private-a` + `app-private-b`,
security group `app-alb-sg` (remove default), listener HTTP 80 → `app-tg`. Create.
Copy its **DNS name**.

**5e. Launch template** – EC2 → Launch templates → Create:
name `app-tier-lt`, AMI **My AMIs → app-tier-ami**, t3.micro, no key pair,
don't choose a subnet, security group `app-sg`, Advanced → IAM instance profile
**LabInstanceProfile**. Create.

**5f. Auto Scaling group** – EC2 → Auto Scaling groups → Create:

| Setting | Value |
|---|---|
| Name / template | `app-asg` / `app-tier-lt` |
| VPC / subnets | `expense-vpc` / `app-private-a`, `app-private-b` |
| Load balancing | Attach to existing → `app-tg` |
| Health checks | tick **Turn on Elastic Load Balancing health checks**, grace period 120 s |
| Group size | desired **2**, min **1**, max **3** |
| Scaling | Target tracking, metric **Average CPU utilization**, target **30** (Node.js uses one of the two vCPUs, so a busy server shows about 50%) |
| Monitoring | tick **Enable group metrics collection** |

Create. After about 3 minutes, `app-tg` → Targets should show **2 healthy**. 📸 this.

**5g.** Terminate `app-build` (the AMI keeps everything).

---

## 6. Web tier

**6a. Build instance** – same as 5a, but name `web-build`, security group `web-sg`
(subnet `web-public-a`, public IP Enable, LabInstanceProfile). Connect with Session Manager:

```bash
sudo -i
aws s3 cp s3://expense-code-<your-roll-no>/scripts/web-setup.sh .
bash web-setup.sh expense-code-<your-roll-no> <app-alb DNS name from 5d>
```

The last line must show `{"status":"ok",...}` – that proves web → internal ALB → app works. 📸

**6b.** Create image `web-tier-ami` from `web-build`; wait for Available.

**6c. Target group** `web-tg`: Instances, HTTP **80**, VPC `expense-vpc`, health check path `/health`.

**6d. Public load balancer** `web-alb`: Application LB, scheme **Internet-facing**,
subnets `web-public-a` + `web-public-b`, security group `web-alb-sg`, listener HTTP 80 → `web-tg`.

**6e. Launch template** `web-tier-lt`: AMI `web-tier-ami`, t3.micro, no key pair,
security group `web-sg`, IAM instance profile LabInstanceProfile.

**6f. Auto Scaling group** `web-asg`: template `web-tier-lt`, subnets `web-public-a` +
`web-public-b`, attach to `web-tg`, ELB health checks on (grace 120 s), desired 2 / min 1 / max 3,
target tracking CPU 50, group metrics on.

**6g.** Terminate `web-build`. When `web-tg` shows 2 healthy targets, open
`http://<web-alb DNS name>` in your browser. 🎉 📸 the working app.

---

## 7. Monitoring (CloudWatch)

CloudWatch → Dashboards → Create `expense-dashboard`, add line widgets:

- EC2 → By Auto Scaling Group → **CPUUtilization** for `app-asg` and `web-asg`
- ApplicationELB → **RequestCount** and **TargetResponseTime** for `web-alb`
- ApplicationELB → **HealthyHostCount** for `app-tg` and `web-tg`

The target-tracking policies already created CloudWatch alarms (CloudWatch → Alarms). 📸 both.

---

## 8. Demo script (rehearse this)

1. **App works** – open the public ALB URL, add three expenses, delete one, refresh:
   data persists in RDS.
2. **Load balancing** – click **Refresh** a few times: the "Served by" web and app server
   names change between instances.
3. **Security** – show RDS "Publicly accessible: No" and the security-group chain.
4. **Self-healing** – EC2 → terminate one `app-asg` instance → the app keeps working (the other
   instance serves) → Auto Scaling group → Activity shows a replacement launching.
5. **Auto scaling** – on a laptop with Node.js:
   `node scripts/loadtest.js http://<web-alb DNS> 30 10`
   Within about 5 minutes app-tier CPU passes 30% → `app-asg` Activity shows it scaling out to 3; the
   load-test output starts listing a third app server. After the test stops, it scales back in
   (this takes around 15 minutes). 📸 the Activity history and CPU graph.

---

## 9. Pause, resume, teardown

**Pause (end of every work day):**
1. `app-asg` and `web-asg` → Edit → desired **0**, min **0**.
2. RDS → `expense-db` → Actions → **Stop temporarily** (AWS restarts it automatically after 7 days).
3. Load balancers keep a small hourly charge. If you won't work on it for several days, delete
   both ALBs (see the note below about recreating them).

**Resume:** start `expense-db` (wait for Available) → set both ASGs back to desired 2 / min 1.

**If you recreate `app-alb`**, its DNS name changes, so the web servers must be told.
Create a new version of `web-tier-lt` and add this as **User data** (Advanced details):

```bash
#!/bin/bash
sed -i "s#proxy_pass http://[^/]*/;#proxy_pass http://NEW-APP-ALB-DNS:80/;#" /etc/nginx/nginx.conf
systemctl restart nginx
```

Then set `web-asg` to use the latest template version and replace its instances
(Instance refresh). RDS keeps the same endpoint as long as you reuse the identifier `expense-db`.

**Teardown after evaluation (in this order):**
1. Delete Auto Scaling groups `web-asg`, `app-asg` (this terminates their instances)
2. Delete load balancers `web-alb`, `app-alb`, then target groups `web-tg`, `app-tg`
3. Delete RDS `expense-db` (untick final snapshot) and the subnet group
4. Deregister AMIs and delete their snapshots (EC2 → Snapshots); delete launch templates
5. Empty and delete the S3 bucket
6. Delete security groups, then the VPC

---

## 10. Screenshot checklist for the report

- [ ] VPC resource map (1)
- [ ] Security groups list with inbound rules (2)
- [ ] S3 bucket contents (3)
- [ ] RDS connectivity, "Publicly accessible: No" (4)
- [ ] `app-setup.sh` output with database reachable (5a)
- [ ] `app-tg` with 2 healthy targets (5f)
- [ ] `web-setup.sh` output (6a)
- [ ] Working app in the browser via the ALB URL (6g)
- [ ] CloudWatch dashboard and alarms (7)
- [ ] Self-healing: Activity history showing a replacement instance (8.4)
- [ ] Scale-out: Activity history and CPU graph during the load test (8.5)

## Troubleshooting

| Problem | Fix |
|---|---|
| Session Manager "Connect" greyed out | Wait 2–3 minutes; check LabInstanceProfile is attached and the instance has a public IP |
| `/health/db` not reachable | `db-sg` must allow 3306 from `app-sg`; check endpoint/password; RDS status must be Available |
| Targets "unhealthy" | Check the target group port (4000 for app, 80 for web) and health check path `/health`; wait for the 120 s grace period |
| Browser shows 502/504 | App tier not healthy yet, or wrong internal ALB DNS in nginx.conf |
| Region error pages | Switch back to us-east-1 |
